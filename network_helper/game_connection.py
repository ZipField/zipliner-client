"""Find the game window and temporarily block its executable in a dynamic WFP session."""
import ctypes as C
from ctypes import wintypes as W
import os
import threading
import time
import uuid

import psutil
from process_target import is_target


class GUID(C.Structure):
    _fields_ = [('data1', W.DWORD), ('data2', W.WORD), ('data3', W.WORD),
                ('data4', C.c_ubyte * 8)]

    @classmethod
    def parse(cls, value):
        return cls.from_buffer_copy(uuid.UUID(value).bytes_le)


class Display(C.Structure):
    _fields_ = [('name', W.LPWSTR), ('description', W.LPWSTR)]


class Blob(C.Structure):
    _fields_ = [('size', W.DWORD), ('data', C.POINTER(C.c_ubyte))]


class ValueData(C.Union):
    _fields_ = [('uint64', C.POINTER(C.c_uint64)), ('blob', C.POINTER(Blob)),
                ('uint32', W.DWORD)]


class Value(C.Structure):
    _anonymous_ = ('value',)
    _fields_ = [('type', W.DWORD), ('value', ValueData)]


class Condition(C.Structure):
    _fields_ = [('key', GUID), ('match', W.DWORD), ('value', Value)]


class Action(C.Structure):
    _fields_ = [('type', W.DWORD), ('key', GUID)]


class Context(C.Union):
    _fields_ = [('raw', C.c_uint64), ('key', GUID)]


class Filter(C.Structure):
    _fields_ = [('key', GUID), ('display', Display), ('flags', W.DWORD),
                ('provider', C.POINTER(GUID)), ('provider_data', Blob),
                ('layer', GUID), ('sublayer', GUID), ('weight', Value),
                ('condition_count', W.DWORD), ('conditions', C.POINTER(Condition)),
                ('action', Action), ('context', Context), ('reserved', C.POINTER(GUID)),
                ('id', C.c_uint64), ('effective_weight', Value)]


class Session(C.Structure):
    _fields_ = [('key', GUID), ('display', Display), ('flags', W.DWORD),
                ('transaction_timeout', W.DWORD), ('pid', W.DWORD),
                ('sid', C.c_void_p), ('username', W.LPWSTR), ('kernel_mode', W.BOOL)]


def game_window_paths(target='Endfield.exe'):
    """Require a visible top-level window owned by the configured executable."""
    processes = {}
    for process in psutil.process_iter(['pid', 'name']):
        try:
            if not is_target(process.pid, target):
                continue
            path = process.exe()
            processes[process.pid] = path
        except (psutil.Error, OSError):
            continue
    if not processes:
        return []
    user = C.WinDLL('user32', use_last_error=True)
    callback_type = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
    user.EnumWindows.argtypes = [callback_type, W.LPARAM]
    user.EnumWindows.restype = W.BOOL
    user.IsWindowVisible.argtypes = [W.HWND]
    user.IsWindowVisible.restype = W.BOOL
    user.GetWindow.argtypes = [W.HWND, W.UINT]
    user.GetWindow.restype = W.HWND
    user.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
    user.GetClientRect.argtypes = [W.HWND, C.POINTER(W.RECT)]
    found = set()

    @callback_type
    def visit(hwnd, _):
        if not user.IsWindowVisible(hwnd) or user.GetWindow(hwnd, 4):  # GW_OWNER
            return True
        pid = W.DWORD()
        user.GetWindowThreadProcessId(hwnd, C.byref(pid))
        rect = W.RECT()
        if (pid.value in processes and user.GetClientRect(hwnd, C.byref(rect))
                and rect.right > rect.left and rect.bottom > rect.top):
            found.add(processes[pid.value])
        return True

    if not user.EnumWindows(visit, 0):
        raise C.WinError(C.get_last_error())
    return sorted(found)


def game_tcp_snapshot(paths):
    """Connection metadata for the verified game executables only; no payloads."""
    wanted = {os.path.normcase(os.path.abspath(path)) for path in paths}
    pids = set()
    for process in psutil.process_iter(['pid', 'name']):
        try:
            if os.path.normcase(os.path.abspath(process.exe())) in wanted:
                pids.add(process.pid)
        except (psutil.Error, OSError):
            continue
    result = []
    for connection in psutil.net_connections(kind='tcp'):
        if connection.pid not in pids:
            continue
        result.append({'pid': connection.pid, 'family': int(connection.family),
                       'status': connection.status,
                       'local': list(connection.laddr) if connection.laddr else None,
                       'remote': list(connection.raddr) if connection.raddr else None})
    return result[:128]


class GameNetworkBlock:
    # ALE policies reauthorize existing flows as well as checking new connections.
    # All ports/protocols, both directions, IPv4 + IPv6, scoped to the executable.
    LAYERS = (
        'c38d57d1-05a7-4c33-904f-7fbceee60e82',
        '4a72393b-319f-44bc-84c3-ba54dcb3b6b4',
        'e1cd9fe7-f4b5-4273-96c0-592e487b8650',
        'a3b42c97-9f04-4672-b87e-cee9c483257f',
    )

    def __init__(self):
        self.api = C.WinDLL('fwpuclnt', use_last_error=True)
        self.handle = W.HANDLE()
        self.lock = threading.RLock()
        self.filter_ids = []
        self.timer = None
        self.cleanup_error = None
        self.committed_at = None
        signatures = {
            'FwpmEngineOpen0': [W.LPCWSTR, W.DWORD, C.c_void_p, C.POINTER(Session), C.POINTER(W.HANDLE)],
            'FwpmEngineClose0': [W.HANDLE],
            'FwpmTransactionBegin0': [W.HANDLE, W.DWORD],
            'FwpmTransactionCommit0': [W.HANDLE],
            'FwpmTransactionAbort0': [W.HANDLE],
            'FwpmGetAppIdFromFileName0': [W.LPCWSTR, C.POINTER(C.POINTER(Blob))],
            'FwpmFreeMemory0': [C.POINTER(C.c_void_p)],
            'FwpmFilterAdd0': [W.HANDLE, C.POINTER(Filter), C.c_void_p, C.POINTER(C.c_uint64)],
            'FwpmFilterDeleteById0': [W.HANDLE, C.c_uint64],
        }
        for name, arguments in signatures.items():
            function = getattr(self.api, name)
            function.argtypes = arguments
            function.restype = None if name == 'FwpmFreeMemory0' else W.DWORD

    @staticmethod
    def check(code):
        if code:
            raise OSError(code, f'Windows 网络控制失败（0x{code:08X}）')

    def open(self, paths, duration=2):
        # The lease belongs to the block, not the UI/control/logging worker.
        # Always arm it before returning a committed (active) policy.
        with self.lock:
            self._open(paths, duration)

    def _open(self, paths, duration):
        if self.handle:
            raise RuntimeError('A temporary game block is already open')
        if not paths or duration <= 0 or duration > 2:
            raise ValueError('Temporary game block requires paths and a lease of at most two seconds')
        session = Session()
        session.display.name = 'Zipliner Client temporary game connection'
        session.flags = 1  # FWPM_SESSION_FLAG_DYNAMIC: close/crash removes all filters.
        self.check(self.api.FwpmEngineOpen0(None, 10, None, C.byref(session), C.byref(self.handle)))
        try:
            self.check(self.api.FwpmTransactionBegin0(self.handle, 0))
            try:
                for path in paths:
                    app = C.POINTER(Blob)()
                    self.check(self.api.FwpmGetAppIdFromFileName0(path, C.byref(app)))
                    try:
                        condition = Condition()
                        condition.key = GUID.parse('d78e1e87-8644-4ea5-9437-d809ecefc971')
                        condition.match = 0  # FWP_MATCH_EQUAL
                        condition.value.type = 12  # FWP_BYTE_BLOB_TYPE
                        condition.value.blob = app
                        for layer in self.LAYERS:
                            rule = Filter()
                            rule.display.name = 'Zipliner Client two-second game reconnect'
                            rule.layer = GUID.parse(layer)
                            rule.condition_count = 1
                            rule.conditions = C.pointer(condition)
                            rule.action.type = 0x1001  # FWP_ACTION_BLOCK
                            ident = C.c_uint64()
                            self.check(self.api.FwpmFilterAdd0(self.handle, C.byref(rule), None, C.byref(ident)))
                            self.filter_ids.append(ident.value)
                    finally:
                        self.api.FwpmFreeMemory0(C.cast(C.byref(app), C.POINTER(C.c_void_p)))
                self.check(self.api.FwpmTransactionCommit0(self.handle))
                self.committed_at = time.monotonic()
                self.timer = threading.Timer(duration, self._expire)
                self.timer.daemon = True
                self.timer.start()
            except BaseException:
                self.api.FwpmTransactionAbort0(self.handle)
                raise
        except BaseException:
            self.close()
            raise

    def _expire(self):
        try:
            self.close()
        except Exception as error:
            # Retain ownership and the error so the helper can retry and report.
            self.cleanup_error = error

    def close(self):
        with self.lock:
            if self.timer:
                self.timer.cancel()
            if not self.handle:
                return
            # Delete our exact filters first; closing the dynamic session is a
            # separate fallback, not the sole way to restore game connectivity.
            remaining = []
            for ident in self.filter_ids:
                code = self.api.FwpmFilterDeleteById0(self.handle, ident)
                if code not in (0, 0x80320003):  # FWP_E_FILTER_NOT_FOUND
                    remaining.append(ident)
            self.filter_ids = remaining
            code = self.api.FwpmEngineClose0(self.handle)
            if code == 0:
                self.handle = W.HANDLE()
                self.filter_ids.clear()
                self.cleanup_error = None
            else:
                # Keep the handle/IDs reachable for shutdown's second attempt.
                self.check(code)
