import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 只查找 `endfield.exe` 的顶层窗口并读取其客户区位置（物理像素）。
/// 不读写游戏内存、不注入、不向游戏发送任何输入或消息。
class GameWindowLocator {
  GameWindowLocator({this.companionPid, String Function()? targetExecutable})
    : _targetExecutable = targetExecutable ?? (() => 'Endfield.exe');
  final String Function() _targetExecutable;
  final int? companionPid;
  String get targetName => _targetExecutable().split(RegExp(r'[\\/]')).last;

  final int _ownPid = Platform.isWindows ? GetCurrentProcessId() : -1;

  bool get isSupported => Platform.isWindows;

  bool hasGameWindow() => isSupported && _findGameWindow() != null;

  /// 找不到游戏窗口时返回 null。
  Rect? findGameClientRect() {
    if (!isSupported) return null;
    final hwnd = _findGameWindow();
    if (hwnd == null) return null;
    final rect = calloc<RECT>();
    final origin = calloc<POINT>();
    try {
      if (GetClientRect(hwnd, rect).value && ClientToScreen(hwnd, origin)) {
        final width = rect.ref.right - rect.ref.left;
        final height = rect.ref.bottom - rect.ref.top;
        if (width > 0 && height > 0) {
          return Rect.fromLTWH(
            origin.ref.x.toDouble(),
            origin.ref.y.toDouble(),
            width.toDouble(),
            height.toDouble(),
          );
        }
      }
      if (GetWindowRect(hwnd, rect).value) {
        return Rect.fromLTRB(
          rect.ref.left.toDouble(),
          rect.ref.top.toDouble(),
          rect.ref.right.toDouble(),
          rect.ref.bottom.toDouble(),
        );
      }
      return null;
    } finally {
      calloc.free(rect);
      calloc.free(origin);
    }
  }

  /// 当前前台窗口属于游戏。
  bool isGameForeground() {
    if (!isSupported) return false;
    final pid = _pidOf(GetForegroundWindow());
    return pid != null && _isGamePid(pid);
  }

  /// 当前前台窗口属于本应用。
  bool isSelfForeground() {
    if (!isSupported) return false;
    final foreground = _pidOf(GetForegroundWindow());
    return foreground == _ownPid ||
        (companionPid != null && foreground == companionPid);
  }

  HWND? _findGameWindow() {
    HWND? best;
    var bestArea = 0;
    HWND? current;
    final rect = calloc<RECT>();
    try {
      while (true) {
        final next = FindWindowEx(null, current, null, null).value;
        if (next.address == 0) break;
        current = next;
        if (!IsWindowVisible(next)) continue;
        if (GetWindow(next, GW_OWNER).value.address != 0) continue;
        final pid = _pidOf(next);
        if (pid == null || !_isGamePid(pid)) continue;
        if (!GetWindowRect(next, rect).value) continue;
        final area =
            (rect.ref.right - rect.ref.left) * (rect.ref.bottom - rect.ref.top);
        if (area > bestArea) {
          best = next;
          bestArea = area;
        }
      }
    } finally {
      calloc.free(rect);
    }
    return best;
  }

  static int? _pidOf(HWND hwnd) {
    if (hwnd.address == 0) return null;
    final pid = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, pid);
      return pid.value == 0 ? null : pid.value;
    } finally {
      calloc.free(pid);
    }
  }

  bool _isGamePid(int pid) {
    if (pid == _ownPid) return false;
    if (pid == companionPid) return false;
    final path = _imagePath(pid)?.toLowerCase();
    final target = _targetExecutable().replaceAll('/', '\\').toLowerCase();
    return path != null &&
        (target.contains('\\')
            ? path == target
            : path.split(RegExp(r'[\\/]')).last == target);
  }

  static String? _imagePath(int pid) {
    final handle = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION,
      false,
      pid,
    ).value;
    if (handle.address == 0) return null;
    final buffer = calloc<Uint16>(1024);
    final size = calloc<Uint32>()..value = 1024;
    try {
      if (!QueryFullProcessImageName(
        handle,
        PROCESS_NAME_WIN32,
        PWSTR(buffer.cast()),
        size,
      ).value) {
        return null;
      }
      final path = PWSTR(buffer.cast()).toDartString(length: size.value);
      return path;
    } finally {
      CloseHandle(handle);
      calloc.free(buffer);
      calloc.free(size);
    }
  }

  List<GameWindowChoice> visibleWindows() {
    if (!isSupported) return const [];
    final result = <GameWindowChoice>[];
    HWND? current;
    final title = calloc<Uint16>(1024);
    try {
      while (true) {
        final next = FindWindowEx(null, current, null, null).value;
        if (next.address == 0) break;
        current = next;
        if (!IsWindowVisible(next) ||
            GetWindow(next, GW_OWNER).value.address != 0) {
          continue;
        }
        final pid = _pidOf(next);
        if (pid == null || pid == _ownPid || pid == companionPid) continue;
        final count = GetWindowText(next, PWSTR(title.cast()), 1024).value;
        if (count <= 0) continue;
        final path = _imagePath(pid);
        if (path == null) continue;
        if (path.toLowerCase() == Platform.resolvedExecutable.toLowerCase()) {
          continue;
        }
        result.add(
          GameWindowChoice(
            PWSTR(title.cast()).toDartString(length: count),
            path,
          ),
        );
      }
    } finally {
      calloc.free(title);
    }
    result.sort((a, b) => a.title.compareTo(b.title));
    return result;
  }
}

class GameWindowChoice {
  const GameWindowChoice(this.title, this.executable);
  final String title;
  final String executable;
}

/// 本应用主窗口的原生句柄操作（仅 Windows，物理像素）。
///
/// window_manager 用 Dart 端的 devicePixelRatio 在逻辑/物理像素间换算，多显示器且缩放不同时
/// 会取错比例（例如副屏 100%、主屏 125%），保存/恢复窗口位置因此会越变越小。这里直接读写物理坐标。
class NativeWindow {
  NativeWindow() : _pid = Platform.isWindows ? GetCurrentProcessId() : -1;

  final int _pid;
  HWND? _hwnd;

  bool get isSupported => Platform.isWindows;

  HWND? get handle {
    if (!isSupported) return null;
    final cached = _hwnd;
    if (cached != null && IsWindow(cached)) return cached;
    return _hwnd = _find();
  }

  /// 窗口所在显示器的缩放比例（1.0 = 100%）。
  double get scale {
    final hwnd = handle;
    if (hwnd == null) return 1;
    final dpi = GetDpiForWindow(hwnd);
    return dpi == 0 ? 1 : dpi / 96;
  }

  Rect? get rect {
    final hwnd = handle;
    if (hwnd == null) return null;
    final r = calloc<RECT>();
    try {
      if (!GetWindowRect(hwnd, r).value) return null;
      return Rect.fromLTRB(
        r.ref.left.toDouble(),
        r.ref.top.toDouble(),
        r.ref.right.toDouble(),
        r.ref.bottom.toDouble(),
      );
    } finally {
      calloc.free(r);
    }
  }

  /// Unlike window_manager's posted SC_RESTORE, this completes the native
  /// state change before the following overlay size is applied.
  void restore() {
    final hwnd = handle;
    if (hwnd != null) ShowWindow(hwnd, SW_RESTORE);
  }

  void configureCoordinateWindow() {
    final hwnd = handle;
    if (hwnd == null) return;
    final style = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
    SetWindowLongPtr(
      hwnd,
      GWL_EXSTYLE,
      (style | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) & ~WS_EX_APPWINDOW,
    );
    SetWindowPos(
      hwnd,
      null,
      0,
      0,
      0,
      0,
      SET_WINDOW_POS_FLAGS(
        SWP_NOMOVE |
            SWP_NOSIZE |
            SWP_NOZORDER |
            SWP_NOACTIVATE |
            SWP_FRAMECHANGED,
      ),
    );
  }

  void setOnTopWithoutActivation(bool value) {
    final hwnd = handle;
    if (hwnd == null) return;
    SetWindowPos(
      hwnd,
      value ? HWND_TOPMOST : HWND_NOTOPMOST,
      0,
      0,
      0,
      0,
      SET_WINDOW_POS_FLAGS(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE),
    );
  }

  void setVisibleWithoutActivation(bool value) {
    final hwnd = handle;
    if (hwnd != null) ShowWindow(hwnd, value ? SW_SHOWNOACTIVATE : SW_HIDE);
  }

  void setRect(Rect rect) {
    final hwnd = handle;
    if (hwnd == null) return;
    SetWindowPos(
      hwnd,
      null,
      rect.left.round(),
      rect.top.round(),
      rect.width.round(),
      rect.height.round(),
      SET_WINDOW_POS_FLAGS(SWP_NOZORDER | SWP_NOACTIVATE),
    );
  }

  void setPosition(Offset position) {
    final hwnd = handle;
    if (hwnd == null) return;
    SetWindowPos(
      hwnd,
      null,
      position.dx.round(),
      position.dy.round(),
      0,
      0,
      SET_WINDOW_POS_FLAGS(SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSIZE),
    );
  }

  HWND? _find() {
    HWND? current;
    HWND? hidden;
    final pid = calloc<Uint32>();
    final className = calloc<Uint16>(128);
    try {
      while (true) {
        final next = FindWindowEx(null, current, null, null).value;
        if (next.address == 0) return hidden;
        current = next;
        GetWindowThreadProcessId(next, pid);
        if (pid.value != _pid || GetWindow(next, GW_OWNER).value.address != 0) {
          continue;
        }
        final length = GetClassName(next, PWSTR(className.cast()), 128).value;
        if (length <= 0 ||
            PWSTR(className.cast()).toDartString(length: length) !=
                'FLUTTER_RUNNER_WIN32_WINDOW') {
          continue;
        }
        if (IsWindowVisible(next)) return next;
        hidden ??= next;
      }
    } finally {
      calloc.free(pid);
      calloc.free(className);
    }
  }
}
