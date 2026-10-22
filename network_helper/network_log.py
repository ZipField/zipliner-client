"""Bounded local event logs; packet diagnostics require explicit opt-in."""
import json
from pathlib import Path
import threading
import time


DIAGNOSTIC_EVENTS = frozenset({
    'PASS_FRAME', 'UL_PASS_FRAME', 'DL_RECV', 'UL_RECV', 'DL_FORWARD',
    'DL_FRAME_BYTES', 'UL_FRAME_BYTES', 'HOLD_POSITION_STARTED',
    'HOLD_POSITION_SAMPLE',
})


class NetworkLog:
    MAX_BYTES = 8 * 1024 * 1024

    def __init__(self, directory, started, diagnostic=False):
        self.path = Path(directory) / 'events.jsonl'
        self.started = started
        self.diagnostic = diagnostic
        self.lock = threading.Lock()
        self.closed = False
        self.file = None
        self.bytes = 0

    def write(self, event, **fields):
        if not self.diagnostic and event in DIAGNOSTIC_EVENTS:
            return
        data = (json.dumps({'seconds': round(time.monotonic()-self.started, 6),
                            'event': event, **fields}) + '\n').encode('utf-8')
        with self.lock:
            if self.closed:
                return
            try:
                if self.file is None:
                    self.file = self.path.open('ab')
                    self.bytes = self.file.tell()
                if self.bytes + len(data) > self.MAX_BYTES:
                    self.file.close()
                    self.file = None
                    self.path.replace(self.path.with_name('events.previous.jsonl'))
                    self.file = self.path.open('ab')
                    self.bytes = 0
                self.file.write(data)
                self.file.flush()
                self.bytes += len(data)
            except OSError:
                # Disk full, permissions or antivirus must not break the relay.
                if self.file is not None:
                    try:
                        self.file.close()
                    except OSError:
                        pass
                    self.file = None

    def close(self):
        with self.lock:
            self.closed = True
            if self.file is not None:
                try:
                    self.file.close()
                except OSError:
                    pass
                self.file = None
