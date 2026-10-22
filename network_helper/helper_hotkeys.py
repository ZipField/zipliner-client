"""Poll only the two configured shortcuts inside the elevated helper."""
import ctypes
import threading


class HelperHotkeys:
    def __init__(self, emit):
        self.emit = emit
        self.lock = threading.Lock()
        self.bindings = {}
        self.suspended = False
        self.revision = 0
        self.was_down = {}
        self.reset_edges = True

    def configure(self, bindings, suspended, revision):
        if not isinstance(bindings, dict) or set(bindings) != {'toggle', 'release'}:
            raise ValueError('Invalid shortcut actions')
        validated = {}
        for action, binding in bindings.items():
            vk, modifiers = binding.get('vk'), binding.get('modifiers')
            if type(vk) is not int or not 1 <= vk <= 254 or vk in (16, 17, 18, 91, 92):
                raise ValueError('Invalid shortcut key')
            if type(modifiers) is not int or not 0 <= modifiers <= 15:
                raise ValueError('Invalid shortcut modifiers')
            validated[action] = (vk, modifiers)
        if validated['toggle'] == validated['release']:
            raise ValueError('Shortcuts must be different')
        if not isinstance(suspended, bool) or type(revision) is not int:
            raise ValueError('Invalid shortcut state')
        with self.lock:
            if self.bindings != validated or self.suspended != suspended:
                self.reset_edges = True
            self.bindings, self.suspended, self.revision = validated, suspended, revision

    def run(self, stop):
        user = ctypes.WinDLL('user32', use_last_error=True)
        user.GetAsyncKeyState.argtypes = [ctypes.c_int]
        user.GetAsyncKeyState.restype = ctypes.c_short
        while not stop.is_set():
            events = []
            with self.lock:
                def down(vk):
                    return bool(user.GetAsyncKeyState(vk) & 0x8000)
                modifiers = ((1 if down(0x11) else 0) |
                             (2 if down(0x12) else 0) |
                             (4 if down(0x10) else 0) |
                             (8 if down(0x5b) or down(0x5c) else 0))
                states = {vk: down(vk) for vk, _ in self.bindings.values()}
                for action, (vk, required) in self.bindings.items():
                    if (not self.reset_edges and not self.suspended and states[vk]
                            and not self.was_down.get(vk, False) and modifiers == required):
                        events.append((action, self.revision))
                self.was_down = states
                self.reset_edges = False
            for action, revision in events:
                self.emit(action, revision)
            stop.wait(0.01)
