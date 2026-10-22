"""Incremental framing with ordered, byte-preserving holds and snapshot releases."""
import hashlib
import time


class DownstreamFilter:
    def __init__(self, enabled, event, clock=time.monotonic,
                 frame_observer=None, raw_frame_event=None, bypass_frame=None,
                 trace_payload=False):
        self.enabled = enabled
        self.event = event
        self.buffer = bytearray()
        self.forwarded = 0
        self.disabled = False
        self.index = 0
        self.clock = clock
        self.hold_started = None
        self.frame_observer = frame_observer
        self.raw_frame_event = raw_frame_event
        self.bypass_frame = bypass_frame
        self.trace_payload = trace_payload
        self.observed_offset = 0
        self.observed_index = 0
        self.observed_bytes = 0
        self.release_through = 0
        self.consumed_bytes = 0

    def release_prefix(self, absolute_end):
        """Authorize only the received prefix ending at this absolute offset."""
        self.release_through = max(self.release_through, absolute_end-self.consumed_bytes)

    def observe_received(self):
        """Inspect complete, sequential frames, including those behind a hold.

        Never search raw payload for a header signature. A positive observer
        result releases original stream bytes only up to that complete frame.
        """
        if self.frame_observer is None and self.raw_frame_event is None:
            return
        while len(self.buffer) - self.observed_offset >= 3:
            start = self.observed_offset
            extra = self.buffer[start]
            if extra > 64:
                return  # Let the ordinary parser handle invalid framing.
            length = int.from_bytes(self.buffer[start+1:start+3], 'little')
            end = start + 3 + extra + length
            if end > len(self.buffer):
                return
            self.observed_index += 1
            fields = {'index': self.observed_index,
                      'stream_offset': self.observed_bytes,
                      'header_hex': bytes(self.buffer[start:start+3]).hex(),
                      'length_field': length, 'frame_bytes': end-start}
            # Capture only xx0400 and xx0000 at validated frame boundaries.
            # The callback does not participate in forwarding or hold decisions.
            if self.raw_frame_event is not None and length in (0, 4):
                frame = bytes(self.buffer[start:end])
                self.raw_frame_event({**fields, 'stream_offset': self.observed_bytes,
                                      'sha256': hashlib.sha256(frame).hexdigest(),
                                      'raw_hex': frame.hex()})
            if self.frame_observer is not None and self.frame_observer(fields):
                self.release_through = end
            self.observed_bytes += end-start
            self.observed_offset = end

    @property
    def holding(self):
        return self.hold_started is not None

    def cancel_hold(self, reason):
        if self.holding:
            self.event('HOLD_CANCELLED', {'index': self.index+1, 'reason': reason,
                                         'held_seconds': self.clock()-self.hold_started})
            self.hold_started = None

    def _emit_pending(self):
        data = bytes(self.buffer[self.forwarded:])
        self.forwarded = len(self.buffer)
        return data

    def _disable(self, reason):
        self.cancel_hold(reason)
        self.disabled = True
        self.event('PARSER_DISABLED', {'reason': reason})
        data = self._emit_pending()
        self.buffer.clear()
        self.forwarded = 0
        return data

    def feed(self, data):
        if self.disabled:
            return data
        self.buffer.extend(data)
        self.observe_received()
        output = bytearray()
        while self.buffer:
            if len(self.buffer) < 3:
                if not self.enabled() or self.forwarded:
                    output.extend(self._emit_pending())
                break
            extra = self.buffer[0]
            length_field = int.from_bytes(self.buffer[1:3], 'little')
            total = 3 + extra + length_field
            if extra > 64:
                output.extend(self._disable('header_byte0_out_of_observed_range'))
                break
            # Observed variants: 100400 / 110400 / 120400 / 130400 (23-26 bytes).
            candidate = extra in (16, 17, 18, 19) and length_field == 4
            should_hold = self.enabled() and candidate and not self.forwarded
            releasing_exit = self.release_through >= total
            bypassing = self.bypass_frame is not None and self.bypass_frame(self.index+1)
            if releasing_exit or bypassing:
                should_hold = False
            if should_hold:
                if not self.holding:
                    self.hold_started = self.clock()
                    self.event('HOLD_FRAME', {'index': self.index+1, 'header_hex': bytes(self.buffer[:3]).hex(),
                                             'length_field': length_field, 'frame_bytes': total,
                                             'delay_seconds': None, 'until_disconnect': True})
                break
            if self.holding:
                self.cancel_hold('region_exit' if releasing_exit else 'filter_off')
            if len(self.buffer) < total:
                output.extend(self._emit_pending())
                break
            frame = bytes(self.buffer[:total])
            self.index += 1
            fields = {'index': self.index, 'header_hex': frame[:3].hex(),
                        'length_field': length_field, 'frame_bytes': total,
                        'candidate': candidate, 'prefix_already_forwarded': self.forwarded,
                        'held_seconds': 0}
            if self.trace_payload:
                fields['sha256'] = hashlib.sha256(frame).hexdigest()
            self.event('PASS_FRAME', fields)
            output.extend(frame[self.forwarded:])
            del self.buffer[:total]
            self.consumed_bytes += total
            self.observed_offset = max(0, self.observed_offset-total)
            self.release_through = max(0, self.release_through-total)
            self.forwarded = 0
            if self.index == 1:
                self.event('PARSER_READY', {'validated_frames': self.index})
        return bytes(output)

    def release_if_off(self):
        if not self.enabled():
            return self.feed(b'')
        return b''

    def tick(self):
        return self.feed(b'')

    def forward_snapshot(self, data=b''):
        """Release this received snapshot, retaining partial-frame forwarding state."""
        original = self.enabled
        self.enabled = lambda: False
        try:
            return self.feed(data)
        finally:
            self.enabled = original

    def abandon_partial(self, reason):
        if not self.buffer or self.disabled:
            return b''
        return self._disable(reason)

    def finish(self):
        if not self.buffer:
            return b''
        return self._disable('EOF_with_partial_frame')
