import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:window_manager/window_manager.dart';

import '../position/follow_placement.dart';
import '../position/position_prefs.dart';
import 'game_window_locator.dart';
import 'global_hotkey.dart';

/// 桌面端坐标悬浮窗。原工具是独立的置顶小窗口；这里把主窗口切换为置顶的小坐标窗，
/// 再按快捷键（默认 F12）或点返回按钮恢复。
///
/// 跟随游戏窗口时背景透明、鼠标穿透，并定期读取 `endfield.exe` 的窗口位置（仅 Windows）。
class DesktopOverlay extends ChangeNotifier {
  DesktopOverlay(this._prefs, {GameWindowLocator? locator}) : _locator = locator ?? GameWindowLocator();

  static bool get isSupported => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static const normalSize = Size(208, 116);
  static const followSize = Size(190, 100);
  static const _followInterval = Duration(milliseconds: 500);
  static const _hideDelay = Duration(seconds: 1);

  final TfPreferencesController _prefs;
  final GameWindowLocator _locator;

  bool active = false;

  /// 本次进入悬浮模式的时间，悬浮窗据此在开头几秒显示“按快捷键返回”。
  DateTime? openedAt;

  /// 跟随失败等非致命提示。
  String? warning;
  String? hotkeyWarning;

  bool get followSupported => _locator.isSupported;

  bool get follow => followSupported && _prefs.get(PositionPrefs.followGame);

  int get decimals => _prefs.get(PositionPrefs.overlayDecimals);

  Size get windowSize =>
      (follow ? followSize : normalSize) *
      (_prefs.get(PositionPrefs.overlayScale) * _prefs.get(TfPreferenceKeys.textScale));

  String get hotkeyLabel => PositionPrefs.hotkeyOf(_prefs).label;

  late final GlobalHotkey _hotkey = GlobalHotkey(() {
    if (!hotkeyPaused) toggle();
  });

  /// 设置新快捷键时暂停，避免按下旧键误切换。
  bool hotkeyPaused = false;
  final NativeWindow _native = NativeWindow();

  /// 进入悬浮模式前的窗口位置。Windows 上是物理像素（见 [NativeWindow]），其他平台是逻辑像素。
  Rect? _savedBounds;
  Timer? _followTimer;
  DateTime _lastFocused = DateTime.now();
  bool _hidden = false;
  bool? _onTop;
  bool? _clickThrough;
  bool _busy = false;

  Future<void> initialize() async {
    if (!isSupported) return;
    await windowManager.ensureInitialized();
    registerHotkey();
  }

  void registerHotkey() {
    if (!isSupported) return;
    final hotkey = PositionPrefs.hotkeyOf(_prefs);
    hotkeyWarning = _hotkey.register(hotkey.key) ? null : '快捷键 ${hotkey.label} 不可用，请换一个按键';
    notifyListeners();
  }

  Future<void> toggle() => active ? close() : open();

  Future<void> open() async {
    if (!isSupported || active || _busy) return;
    _busy = true;
    try {
      _savedBounds = _native.isSupported ? _native.rect : await windowManager.getBounds();
      active = true;
      openedAt = DateTime.now();
      notifyListeners();
      await _applyStyle();
    } finally {
      _busy = false;
    }
  }

  Future<void> close() async {
    if (!active || _busy) return;
    _busy = true;
    try {
      _stopFollow();
      active = false;
      warning = null;
      notifyListeners();
      await _setClickThrough(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setResizable(true);
      final saved = _savedBounds;
      if (saved != null) {
        _native.isSupported ? _native.setRect(saved) : await windowManager.setBounds(saved);
      }
      await windowManager.show();
      await windowManager.focus();
    } finally {
      _busy = false;
    }
  }

  /// 跟随开关或显示位置变化后重新应用样式。
  Future<void> refresh() async {
    if (active) await _applyStyle();
    notifyListeners();
  }

  Future<void> _applyStyle() async {
    _stopFollow();
    // 不调用 setSkipTaskbar：window_manager 在 Windows 上的实现会让进程卡死或退出。
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    // Windows 隐藏标题栏仍保留原生边框；浮窗需要完全无框。
    // close() 的 TitleBarStyle.normal 会恢复普通窗口。
    if (Platform.isWindows) await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.setBackgroundColor(const Color(0x00000000));
    if (follow) {
      await _resize(windowSize);
      // 先保持可点击，找到游戏窗口后再开启鼠标穿透，避免小窗点不动又回不去。
      await _setClickThrough(false);
      _lastFocused = DateTime.now();
      _followTimer = Timer.periodic(_followInterval, (_) => _followTick());
      await _followTick();
    } else {
      await _setClickThrough(false);
      await _resize(windowSize);
      await _setOnTop(true);
      await windowManager.show();
    }
  }

  Future<void> _setClickThrough(bool value) async {
    if (!Platform.isWindows || _clickThrough == value) return;
    _clickThrough = value;
    await windowManager.setIgnoreMouseEvents(value);
  }

  /// 按窗口所在显示器的实际缩放设置逻辑尺寸。
  Future<void> _resize(Size logical) async {
    final rect = _native.rect;
    if (rect == null) return windowManager.setSize(logical);
    final scale = _native.scale;
    _native.setRect(Rect.fromLTWH(rect.left, rect.top, logical.width * scale, logical.height * scale));
  }

  void _stopFollow() {
    _followTimer?.cancel();
    _followTimer = null;
    _onTop = null;
    _hidden = false;
  }

  Future<void> _setOnTop(bool value) async {
    if (_onTop == value) return;
    _onTop = value;
    await windowManager.setAlwaysOnTop(value);
  }

  Future<void> _setHidden(bool value) async {
    if (_hidden == value) return;
    _hidden = value;
    value ? await windowManager.hide() : await windowManager.show(inactive: true);
  }

  Future<void> _followTick() async {
    if (!active || !follow) return;
    final game = _locator.findGameClientRect();
    if (game == null) {
      _setWarning('未找到 endfield.exe 游戏窗口，坐标窗暂时保持可点击');
      await _setClickThrough(false);
      await _setOnTop(false);
      await _setHidden(false);
      return;
    }
    await _setClickThrough(true);

    final gameForeground = _locator.isGameForeground();
    final selfForeground = _locator.isSelfForeground();
    if (gameForeground) {
      _lastFocused = DateTime.now();
      await _setOnTop(true);
      await _setHidden(false);
    } else if (selfForeground) {
      _lastFocused = DateTime.now();
      await _setOnTop(false);
      await _setHidden(false);
    } else if (DateTime.now().difference(_lastFocused) >= _hideDelay) {
      await _setHidden(true);
    }

    _setWarning(null);
    // 游戏窗口是物理像素。按本窗口所在显示器的缩放换算成逻辑像素计算位置，再换回物理像素摆放，
    // 这样边距和偏移在不同缩放的显示器上观感一致。
    final scale = _native.scale;
    final logical = Rect.fromLTRB(game.left / scale, game.top / scale, game.right / scale, game.bottom / scale);
    final position = PositionPrefs.position(_prefs);
    final offset = PositionPrefs.offset(_prefs, position);
    final target = FollowWindowPlacement.calculate(logical, windowSize, position, offset.h, offset.v);
    _native.setPosition(target * scale);
  }

  void _setWarning(String? value) {
    if (warning == value) return;
    warning = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopFollow();
    _hotkey.unregister();
    super.dispose();
  }
}
