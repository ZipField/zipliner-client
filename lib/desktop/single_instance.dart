import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../core/app_info.dart';

/// Windows 上只允许运行一个实例：重复打开时把已有窗口切到前台，避免两个实例同时响应快捷键。
abstract final class SingleInstance {
  static const _mutexName = r'Local\ZiplinerClient.SingleInstance';
  static const _synchronize = 0x00100000;

  // 进程存活期间持有互斥量句柄，退出时由系统释放。
  static int _handle = 0;

  /// 已有实例在运行时返回 false。
  static bool acquire() {
    if (!Platform.isWindows) return true;
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final openMutex = kernel32
        .lookupFunction<IntPtr Function(Uint32, Int32, Pointer<Utf16>), int Function(int, int, Pointer<Utf16>)>(
          'OpenMutexW',
        );
    final createMutex = kernel32
        .lookupFunction<IntPtr Function(Pointer, Int32, Pointer<Utf16>), int Function(Pointer, int, Pointer<Utf16>)>(
          'CreateMutexW',
        );
    final name = _mutexName.toNativeUtf16();
    try {
      if (openMutex(_synchronize, 0, name) != 0) return false;
      _handle = createMutex(nullptr, 0, name);
      return true;
    } finally {
      calloc.free(name);
    }
  }

  /// 把已在运行的实例窗口还原并切到前台。
  static void activateExisting() {
    if (!Platform.isWindows) return;
    final title = AppInfo.name.toNativeUtf16();
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      final hwnd = FindWindowEx(null, null, PCWSTR(className), PCWSTR(title)).value;
      if (hwnd.address == 0) return;
      ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
    } finally {
      calloc.free(title);
      calloc.free(className);
    }
  }

  static bool get held => _handle != 0;
}
