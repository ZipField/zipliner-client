"""Unload WinDivert after our handles close; never terminate another consumer."""
import ctypes
from ctypes import wintypes as w
import time


class ServiceStatus(ctypes.Structure):
    _fields_ = [(name, w.DWORD) for name in (
        'kind', 'state', 'controls', 'exit_code', 'specific', 'checkpoint', 'hint')]


class ReflectData(ctypes.Structure):
    _fields_ = [('timestamp', ctypes.c_int64), ('pid', w.DWORD),
                ('layer', ctypes.c_int), ('flags', ctypes.c_uint64),
                ('priority', ctypes.c_int16)]


class Address(ctypes.Structure):
    _fields_ = [('timestamp', ctypes.c_int64), ('bits', w.DWORD),
                ('reserved', w.DWORD), ('data', ctypes.c_ubyte * 64)]


def active_consumers():
    # Same snapshot protocol as the official windivertctl list command.
    # NO_INSTALL ensures this check never installs or restarts a driver.
    from pydivert import windivert_dll
    dll = ctypes.WinDLL(str(windivert_dll.DLL_PATH), use_last_error=True)
    dll.WinDivertOpen.argtypes = [ctypes.c_char_p, ctypes.c_int,
                                 ctypes.c_int16, ctypes.c_uint64]
    dll.WinDivertOpen.restype = w.HANDLE
    dll.WinDivertShutdown.argtypes = [w.HANDLE, ctypes.c_int]
    dll.WinDivertShutdown.restype = w.BOOL
    dll.WinDivertRecv.argtypes = [w.HANDLE, ctypes.c_void_p, w.UINT,
                                 ctypes.POINTER(w.UINT), ctypes.POINTER(Address)]
    dll.WinDivertRecv.restype = w.BOOL
    dll.WinDivertClose.argtypes = [w.HANDLE]
    dll.WinDivertClose.restype = w.BOOL
    handle = dll.WinDivertOpen(b'true', 4, 0, 0x1 | 0x4 | 0x10)
    if handle == ctypes.c_void_p(-1).value:
        code = ctypes.get_last_error()
        if code == 1060:  # Driver is not loaded.
            return []
        raise ctypes.WinError(code)
    try:
        if not dll.WinDivertShutdown(handle, 3):
            raise ctypes.WinError(ctypes.get_last_error())
        packet = ctypes.create_string_buffer(65535)
        address, length = Address(), w.UINT()
        pids = set()
        for _ in range(65536):
            if not dll.WinDivertRecv(handle, packet, len(packet),
                                     ctypes.byref(length), ctypes.byref(address)):
                code = ctypes.get_last_error()
                if code == 232:  # ERROR_NO_DATA: snapshot drained.
                    return sorted(pids)
                raise ctypes.WinError(code)
            if (address.bits >> 8) & 0xff == 8:  # REFLECT_OPEN
                data = ReflectData.from_buffer_copy(address.data)
                pids.add(data.pid)
        raise RuntimeError('WinDivert handle snapshot exceeded its limit')
    finally:
        if not dll.WinDivertClose(handle):
            raise ctypes.WinError(ctypes.get_last_error())


def unload_driver(log):
    """Return only after STOPPED and service removal, or raise a visible error."""
    api = ctypes.WinDLL('advapi32', use_last_error=True)
    api.OpenSCManagerW.argtypes = [w.LPCWSTR, w.LPCWSTR, w.DWORD]
    api.OpenSCManagerW.restype = w.HANDLE
    api.OpenServiceW.argtypes = [w.HANDLE, w.LPCWSTR, w.DWORD]
    api.OpenServiceW.restype = w.HANDLE
    api.QueryServiceStatus.argtypes = [w.HANDLE, ctypes.POINTER(ServiceStatus)]
    api.QueryServiceStatus.restype = w.BOOL
    api.ControlService.argtypes = [w.HANDLE, w.DWORD, ctypes.POINTER(ServiceStatus)]
    api.ControlService.restype = w.BOOL
    api.DeleteService.argtypes = [w.HANDLE]
    api.DeleteService.restype = w.BOOL
    api.CloseServiceHandle.argtypes = [w.HANDLE]
    api.CloseServiceHandle.restype = w.BOOL
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, w.BOOL, w.LPCWSTR]
    kernel.CreateMutexW.restype = w.HANDLE
    kernel.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
    kernel.WaitForSingleObject.restype = w.DWORD
    kernel.ReleaseMutex.argtypes = [w.HANDLE]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    mutex = kernel.CreateMutexW(None, False, 'WinDivertDriverInstallMutex')
    if not mutex:
        raise ctypes.WinError(ctypes.get_last_error())
    acquired = False
    manager = service = None
    try:
        acquired = kernel.WaitForSingleObject(mutex, 2000) in (0, 0x80)
        if not acquired:
            raise RuntimeError('驱动正在被其他程序操作，请稍后退出或重启电脑。')
        manager = api.OpenSCManagerW(None, None, 1)
        if not manager:
            raise ctypes.WinError(ctypes.get_last_error())
        service = api.OpenServiceW(manager, 'WinDivert', 0x4 | 0x20 | 0x10000)
        if not service:
            code = ctypes.get_last_error()
            if code == 1060:
                log('DRIVER_UNLOADED', already_absent=True)
                return
            raise ctypes.WinError(code)
        status = ServiceStatus()
        def query():
            if not api.QueryServiceStatus(service, ctypes.byref(status)):
                raise ctypes.WinError(ctypes.get_last_error())
            return status.state
        if query() != 1:
            consumers = active_consumers()
            if consumers:
                log('DRIVER_UNLOAD_BUSY', pids=consumers)
                raise RuntimeError('驱动仍被程序占用（PID：' + ', '.join(map(str, consumers)) +
                                   '），请退出相关网络工具后重试；无法处理时请重启电脑。')
            if not api.ControlService(service, 1, ctypes.byref(status)):
                code = ctypes.get_last_error()
                if code != 1062:
                    raise ctypes.WinError(code)
            deadline = time.monotonic() + 5
            while query() != 1:
                if time.monotonic() >= deadline:
                    raise RuntimeError('驱动停止超时，请重启电脑完成卸载。')
                time.sleep(0.05)
        if not api.DeleteService(service):
            code = ctypes.get_last_error()
            if code != 1072:  # Already marked for deletion.
                raise ctypes.WinError(code)
        log('DRIVER_UNLOADED')
    finally:
        if service:
            api.CloseServiceHandle(service)
        if manager:
            api.CloseServiceHandle(manager)
        if acquired:
            kernel.ReleaseMutex(mutex)
        kernel.CloseHandle(mutex)
