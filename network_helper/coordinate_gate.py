"""Connection-local menu allowances and position-confirmed stream prefix releases."""
from collections import deque
import math
import threading
import time


class PositionEvidence:
    def __init__(self):
        self.lock = threading.RLock()
        self.samples = deque(maxlen=512)
        self.latest = None
        self.revision = 0

    def update(self, sample):
        if not isinstance(sample, dict):
            raise ValueError('position must be an object')
        valid = sample.get('valid') is True
        if valid:
            for key in ('x', 'y', 'z', 'observed_at_ms'):
                value = sample.get(key)
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                    raise ValueError('invalid position ' + key)
            if not all(isinstance(sample.get(k), str) and sample[k] for k in ('map', 'level', 'role')):
                raise ValueError('position identity missing')
            if sample.get('outside') not in (True, False, None):
                raise ValueError('invalid position classification')
        value = dict(sample, received_at=time.monotonic())
        with self.lock:
            self.revision += 1
            value['_revision'] = self.revision
            self.latest = value
            self.samples.append(value)

    def baseline(self):
        with self.lock:
            sample = self.latest
            if not sample or not sample.get('valid') or time.time()*1000-sample['observed_at_ms'] > 3000:
                return None
            return sample.copy()

    def confirms(self, pending):
        baseline = pending['baseline']
        if baseline is None:
            return False
        with self.lock:
            for sample in self.samples:
                if (not sample.get('valid') or sample.get('role') != baseline.get('role')
                        or sample.get('outside') is not True
                        or not pending['wall_ms'] <= sample['observed_at_ms'] <= pending['wall_ms']+1000
                        or sample['received_at'] > pending['deadline']):
                    continue
                if any(sample[k] != baseline[k] for k in ('x', 'y', 'z', 'map', 'level')):
                    return True
        return False

    def start_watch(self):
        with self.lock:
            return self.revision, self.baseline()

    def position_updates(self, watch):
        with self.lock:
            return [sample.copy() for sample in self.samples
                    if sample['_revision'] > watch['cursor']]


class ConnectionGate:
    def __init__(self, state, evidence, log):
        self.state, self.evidence, self.log = state, evidence, log
        self.lock = threading.RLock()
        self.menu_tokens = deque()
        self.bypassed = set()
        self.sequence_header = None
        self.sequence_count = 0
        self.sequence_index = 0
        self.pending = []
        self.hold_watch = None
        self.revision = state.revision()
        self.generation = state.snapshot()['generation']

    def upload_frame(self, fields):
        with self.lock:
            self.sync()
            if fields['length_field'] == 2 and self.state.active():
                self.menu_tokens.append((time.monotonic(), fields['index']))
                self.log('MENU_REQUEST', index=fields['index'], valid_seconds=1)

    def observe(self, fields):
        with self.lock:
            return self._observe(fields)

    def _observe(self, fields):
        self.sync()
        if not self.state.active():
            return False
        # Match validated frames, never recv chunks or byte patterns inside a
        # payload. The run can span reads but must be adjacent in this stream.
        if fields['index'] != self.sequence_index+1:
            self.sequence_header = None
            self.sequence_count = 0
        if fields['length_field'] == 4:
            if self.sequence_count == 7:
                self.bypassed.add(fields['index'])
                self.log('SEQUENCE_ALLOW_NEXT', index=fields['index'],
                         header_hex=fields['header_hex'], preceding_header_hex=self.sequence_header,
                         preceding_count=7)
            else:
                if self.menu_tokens:
                    requested_at, request_index = self.menu_tokens.popleft()
                    self.bypassed.add(fields['index'])
                    self.log('MENU_ALLOW_NEXT', index=fields['index'], header_hex=fields['header_hex'],
                             request_index=request_index, request_age_seconds=time.monotonic()-requested_at)
        header = fields['header_hex']
        if header in ('0f1600', '101600', '111600', '121600'):
            self.sequence_count = min(self.sequence_count+1, 8) if header == self.sequence_header else 1
            self.sequence_header = header
        else:
            self.sequence_header = None
            self.sequence_count = 0
        self.sequence_index = fields['index']
        if fields['length_field'] == 0:
            # Freeze the prefix at this complete frame. Later arrivals are never
            # added to this request, even while waiting for position evidence.
            pending = {'index': fields['index'],
                       'end': fields['stream_offset']+fields['frame_bytes'],
                       'deadline': time.monotonic()+1, 'wall_ms': time.time()*1000,
                       'baseline': self.evidence.baseline()}
            self.pending.append(pending)
            self.log('REGION_PENDING', index=fields['index'], end_offset=pending['end'],
                     header_hex=fields['header_hex'], baseline=pending['baseline'])
        return False

    def sync(self):
        with self.lock:
            self._sync()

    def _sync(self):
        revision = self.state.revision()
        snapshot = self.state.snapshot()
        generation = snapshot['generation']
        if revision != self.revision or generation != self.generation or not snapshot['enabled']:
            self.pending.clear()
            self.hold_watch = None
            self.sequence_header = None
            self.sequence_count = 0
            self.sequence_index = 0
            if generation != self.generation or not snapshot['enabled']:
                with self.lock:
                    self.menu_tokens.clear()
                    self.bypassed.clear()
            self.revision = revision
            self.generation = generation
        now = time.monotonic()
        while self.menu_tokens and now-self.menu_tokens[0][0] >= 1:
            requested_at, request_index = self.menu_tokens.popleft()
            self.log('MENU_REQUEST_EXPIRED', index=request_index, age_seconds=now-requested_at)

    def hold_started(self, fields):
        with self.lock:
            self.sync()
            if not self.state.active():
                return
            started = time.monotonic()
            wall_ms = time.time()*1000
            cursor, baseline = self.evidence.start_watch()
            self.hold_watch = {'index': fields['index'], 'started': started,
                               'cursor': cursor, 'last_observed_ms': wall_ms,
                               'role': baseline.get('role') if baseline else None,
                               'previous': baseline,
                               'normal_samples': 0}
            self.log('HOLD_POSITION_STARTED', index=fields['index'],
                     required_normal_samples=2, baseline=baseline)

    def hold_ended(self):
        with self.lock:
            self.hold_watch = None

    def _check_hold_position(self, decoder):
        watch = self.hold_watch
        if watch is None:
            return False
        if not decoder.holding or decoder.index+1 != watch['index']:
            self.hold_watch = None
            return False
        for sample in self.evidence.position_updates(watch):
            watch['cursor'] = sample['_revision']
            if sample['received_at'] < watch['started']:
                continue
            if not sample.get('valid'):
                if watch['normal_samples']:
                    self.log('HOLD_POSITION_RESET', index=watch['index'], reason='position_unavailable')
                watch['normal_samples'] = 0
                watch['role'] = None
                watch['previous'] = None
                continue
            if sample['observed_at_ms'] <= watch['last_observed_ms']:
                continue  # Duplicate config publications never count twice.
            watch['last_observed_ms'] = sample['observed_at_ms']
            previous = watch['previous']
            if watch['role'] is not None and sample['role'] != watch['role']:
                watch['normal_samples'] = 0
                previous = None
                self.log('HOLD_POSITION_RESET', index=watch['index'], reason='role_changed')
            watch['role'] = sample['role']
            watch['previous'] = sample
            changed = previous is not None and any(sample[k] != previous[k] for k in ('x', 'y', 'z'))
            if sample.get('outside') is not True:
                watch['normal_samples'] = 0
            elif changed:
                watch['normal_samples'] += 1
            self.log('HOLD_POSITION_SAMPLE', index=watch['index'],
                     consecutive_normal=watch['normal_samples'], outside=sample.get('outside'), changed=changed,
                     map=sample['map'], level=sample['level'], x=sample['x'], y=sample['y'], z=sample['z'],
                     observed_at_ms=sample['observed_at_ms'])
            if watch['normal_samples'] >= 2:
                self.hold_watch = None
                if self.state.region_exited():
                    self.log('HOLD_POSITION_CONFIRMED', index=watch['index'],
                             consecutive_normal=watch['normal_samples'],
                             elapsed_seconds=time.monotonic()-watch['started'])
                    return True
                return False
        return False

    def bypass(self, index):
        with self.lock:
            return index in self.bypassed

    def forwarded(self, index):
        with self.lock:
            self.bypassed.discard(index)

    def tick(self, decoder):
        with self.lock:
            return self._tick(decoder)

    def _tick(self, decoder):
        self.sync()
        remaining = []
        for item in self.pending:
            if item['end'] <= decoder.consumed_bytes:
                continue  # Already forwarded; do not reset a later hold's timer.
            if self.evidence.confirms(item):
                if self.state.region_exited():
                    decoder.release_prefix(item['end'])
                    self.log('REGION_CONFIRMED', index=item['index'], end_offset=item['end'])
            elif time.monotonic() >= item['deadline']:
                self.log('REGION_REJECTED', index=item['index'], reason='no_changed_normal_position_within_one_second')
            else:
                remaining.append(item)
        self.pending = remaining
        return self._check_hold_position(decoder)
