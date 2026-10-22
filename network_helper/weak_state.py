"""Thread-safe session state; its clock survives game reconnects."""
import math
import threading
import time


class WeakState:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lock = threading.RLock()
        self.enabled = False
        self.maximum = 20
        self.release_revision = 0
        self.started = None
        self.generation = 0

    def configure(self, maximum):
        if isinstance(maximum, bool) or not isinstance(maximum, (int, float)) or not math.isfinite(maximum) or not 10 <= maximum <= 30:
            raise ValueError('maximum must be between 10 and 30 seconds')
        with self.lock:
            self.maximum = maximum

    def enable(self, value):
        if not isinstance(value, bool):
            raise ValueError('enabled must be boolean')
        with self.lock:
            if self.enabled != value:
                self.started = None
                self.generation += 1
            self.enabled = value

    def release_all(self):
        with self.lock:
            if self.enabled:
                self.release_revision += 1
                self.started = None

    def revision(self):
        with self.lock:
            return self.release_revision

    def tick(self):
        with self.lock:
            now = self.clock()
            if self.enabled and self.started is not None and now - self.started >= self.maximum:
                self.release_all()

    def active(self):
        self.tick()
        with self.lock:
            return self.enabled

    def region_exited(self):
        with self.lock:
            if not self.enabled:
                return False
            # The decoder releases only through the observed exit, preserving
            # detection of a later entry in the same receive buffer.
            self.started = None
            return True

    def hold_started(self):
        with self.lock:
            if self.enabled and self.started is None:
                self.started = self.clock()

    def snapshot(self):
        self.tick()
        with self.lock:
            return {'enabled': self.enabled,
                    'generation': self.generation,
                    'maximum': self.maximum, 'release_revision': self.release_revision,
                    'elapsed': 0 if self.started is None else max(0, self.clock() - self.started),
                    'remaining': None if self.started is None else
                    max(0, math.ceil(self.maximum - (self.clock() - self.started)))}
