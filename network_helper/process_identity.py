"""Query the running process token, independently of UAC prompt visibility."""
import ctypes as C
from ctypes import wintypes as W
import os
import sys


class SidAndAttributes(C.Structure):
    _fields_ = [('sid', C.c_void_p), ('attributes', W.DWORD)]


def process_identity():
    kernel = C.WinDLL('kernel32', use_last_error=True)
    api = C.WinDLL('advapi32', use_last_error=True)
    kernel.GetCurrentProcess.restype = W.HANDLE
    kernel.CloseHandle.argtypes = [W.HANDLE]
    api.OpenProcessToken.argtypes = [W.HANDLE, W.DWORD, C.POINTER(W.HANDLE)]
    api.OpenProcessToken.restype = W.BOOL
    api.GetTokenInformation.argtypes = [W.HANDLE, C.c_int, C.c_void_p,
                                       W.DWORD, C.POINTER(W.DWORD)]
    api.GetTokenInformation.restype = W.BOOL
    api.GetSidSubAuthorityCount.argtypes = [C.c_void_p]
    api.GetSidSubAuthorityCount.restype = C.POINTER(C.c_ubyte)
    api.GetSidSubAuthority.argtypes = [C.c_void_p, W.DWORD]
    api.GetSidSubAuthority.restype = C.POINTER(W.DWORD)
    shell = C.WinDLL('shell32', use_last_error=True)
    shell.IsUserAnAdmin.argtypes = []
    shell.IsUserAnAdmin.restype = W.BOOL
    token = W.HANDLE()
    if not api.OpenProcessToken(kernel.GetCurrentProcess(), 0x8, C.byref(token)):
        raise C.WinError(C.get_last_error())
    try:
        def dword(info_class):
            value, size = W.DWORD(), W.DWORD()
            if not api.GetTokenInformation(token, info_class, C.byref(value),
                                           C.sizeof(value), C.byref(size)):
                raise C.WinError(C.get_last_error())
            return value.value
        elevated = bool(dword(20))  # TokenElevation, not group membership.
        elevation_type = dword(18)
        size = W.DWORD()
        if api.GetTokenInformation(token, 25, None, 0, C.byref(size)):
            raise RuntimeError('Unexpected empty TokenIntegrityLevel result')
        if C.get_last_error() != 122 or size.value < C.sizeof(SidAndAttributes):
            raise C.WinError(C.get_last_error())
        buffer = C.create_string_buffer(size.value)
        if not api.GetTokenInformation(token, 25, buffer, size, C.byref(size)):
            raise C.WinError(C.get_last_error())
        label = SidAndAttributes.from_buffer(buffer)
        count = api.GetSidSubAuthorityCount(label.sid)
        if not count or count[0] == 0:
            raise RuntimeError('Token integrity SID is invalid')
        rid = api.GetSidSubAuthority(label.sid, count[0]-1)
        if not rid:
            raise C.WinError(C.get_last_error())
        return {'pid': os.getpid(), 'parent_pid': os.getppid(),
                'executable': os.path.abspath(sys.executable),
                'elevated': elevated, 'elevation_type': elevation_type,
                'integrity_rid': rid[0], 'admin_member': bool(shell.IsUserAnAdmin())}
    finally:
        kernel.CloseHandle(token)
