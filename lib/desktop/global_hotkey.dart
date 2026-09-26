import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:win32/win32.dart' show GetAsyncKeyState;

/// 单键全局快捷键。
///
/// - Windows：每 40ms 读取一次该键的按下状态（`GetAsyncKeyState`），游戏在前台时同样有效。
///   只读取键盘状态，不安装键盘钩子、不拦截按键。
/// - 其他桌面平台：只在本应用窗口获得焦点时响应。
class GlobalHotkey {
  GlobalHotkey(this.onPressed);

  static const _pollInterval = Duration(milliseconds: 40);

  final void Function() onPressed;

  Timer? _timer;
  PhysicalKeyboardKey? _key;
  bool _wasDown = false;

  /// 该键能否作为快捷键（Windows 上需要对应的虚拟键码）。
  static bool supports(PhysicalKeyboardKey key) => !Platform.isWindows || virtualKeyOf(key) != null;

  /// 注册成功返回 true。
  bool register(PhysicalKeyboardKey key) {
    unregister();
    _key = key;
    if (Platform.isWindows) {
      final vk = virtualKeyOf(key);
      if (vk == null) return false;
      // 先读一次，清掉注册前遗留的“按下过”标记。
      _wasDown = (GetAsyncKeyState(vk) & 0x8000) != 0;
      _timer = Timer.periodic(_pollInterval, (_) {
        final state = GetAsyncKeyState(vk);
        final down = (state & 0x8000) != 0;
        // 最低位表示自上次查询以来被按下过，能捕捉到短于轮询间隔的快速点按。
        if (!_wasDown && (down || (state & 0x0001) != 0)) onPressed();
        _wasDown = down;
      });
    } else {
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    return true;
  }

  void unregister() {
    _timer?.cancel();
    _timer = null;
    if (_key != null && !Platform.isWindows) HardwareKeyboard.instance.removeHandler(_onKey);
    _key = null;
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && event.physicalKey == _key) {
      onPressed();
      return true;
    }
    return false;
  }

  /// USB HID 用法码 → Windows 虚拟键码。
  static int? virtualKeyOf(PhysicalKeyboardKey key) {
    final usage = key.usbHidUsage;
    if (usage >> 16 != 0x07) return null;
    final code = usage & 0xFFFF;
    if (code >= 0x04 && code <= 0x1d) return 0x41 + code - 0x04; // A-Z
    if (code >= 0x1e && code <= 0x26) return 0x31 + code - 0x1e; // 1-9
    if (code == 0x27) return 0x30; // 0
    if (code >= 0x3a && code <= 0x45) return 0x70 + code - 0x3a; // F1-F12
    if (code >= 0x68 && code <= 0x73) return 0x7c + code - 0x68; // F13-F24
    if (code >= 0x59 && code <= 0x61) return 0x61 + code - 0x59; // Numpad 1-9
    return _special[code];
  }

  static const _special = {
    0x62: 0x60, // Numpad 0
    0x28: 0x0D, // Enter
    0x29: 0x1B, // Esc
    0x2a: 0x08, // Backspace
    0x2b: 0x09, // Tab
    0x2c: 0x20, // Space
    0x2d: 0xBD, // -
    0x2e: 0xBB, // =
    0x2f: 0xDB, // [
    0x30: 0xDD, // ]
    0x31: 0xDC, // \
    0x33: 0xBA, // ;
    0x34: 0xDE, // '
    0x35: 0xC0, // `
    0x36: 0xBC, // ,
    0x37: 0xBE, // .
    0x38: 0xBF, // /
    0x46: 0x2C, // Print Screen
    0x47: 0x91, // Scroll Lock
    0x48: 0x13, // Pause
    0x49: 0x2D, // Insert
    0x4a: 0x24, // Home
    0x4b: 0x21, // Page Up
    0x4c: 0x2E, // Delete
    0x4d: 0x23, // End
    0x4e: 0x22, // Page Down
    0x4f: 0x27, // Right
    0x50: 0x25, // Left
    0x51: 0x28, // Down
    0x52: 0x26, // Up
  };
}
