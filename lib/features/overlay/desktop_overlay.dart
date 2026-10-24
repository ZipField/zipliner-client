import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:window_manager/window_manager.dart';

import 'package:zipliner_client/features/overlay/follow_placement.dart';
import 'package:zipliner_client/app/app_preferences.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/features/weak_network/weak_network_controller.dart';
import 'package:zipliner_client/features/overlay/coordinate_window_host.dart';
import 'package:zipliner_client/platform/desktop/game_window_locator.dart';
import 'package:zipliner_client/platform/desktop/global_hotkey.dart';

/// 独立坐标窗口。主程序持有状态与快捷键，显示进程只接收坐标和显示设置。
///
/// 跟随游戏窗口时背景透明、鼠标穿透，并定期读取 `endfield.exe` 的窗口位置（仅 Windows）。
class DesktopOverlay extends ChangeNotifier with WindowListener {
  DesktopOverlay(this._prefs, {GameWindowLocator? locator})
    : _locator = locator ?? GameWindowLocator(),
      _isWindow = false,
      _onReturn = null;

  DesktopOverlay.window(
    this._prefs, {
    required this._locator,
    required this._onReturn,
  }) : _isWindow = true;

  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static const normalSize = Size(208, 116);
  static const followSize = Size(190, 100);
  static const _targetExtraHeight = 22.0;
  static const _followInterval = Duration(milliseconds: 500);
  static const _hideDelay = Duration(seconds: 1);

  final TfPreferencesController _prefs;
  final GameWindowLocator _locator;
  final bool _isWindow;
  final VoidCallback? _onReturn;
  CoordinateWindowHost? _host;
  PositionMonitor? _monitor;
  WeakNetworkController? _weakNetwork;
  bool _remoteCoordinates = true;
  String? _remoteWeakStatus;
  bool _syncPending = false;
  bool _windowFailed = false;
  bool _weakWasVisible = false;
  bool _initialized = false;
  bool _disposed = false;

  void attachMonitor(PositionMonitor monitor) {
    _monitor?.removeListener(_sendSnapshot);
    _monitor = monitor;
    monitor.addListener(_sendSnapshot);
  }

  void attachWeakNetwork(WeakNetworkController controller) {
    _weakNetwork?.removeListener(_weakChanged);
    _weakNetwork = controller;
    controller.addListener(_weakChanged);
  }

  bool get showCoordinates => !_isWindow || _remoteCoordinates;
  String? get weakNetworkText =>
      _isWindow ? _remoteWeakStatus : _weakNetwork?.overlayStatus;
  bool get _needsWindow => active || weakNetworkText != null;

  void _weakChanged() {
    if (_disposed) return;
    final visible = weakNetworkText != null;
    if (visible && !_weakWasVisible) _windowFailed = false;
    _weakWasVisible = visible;
    unawaited(_syncWindow());
    notifyListeners();
  }

  /// Only the display process consumes this; coordinate and weak-network
  /// visibility are independent of whether its native window is running.
  Future<void> updatePresentation(
    Map<String, dynamic> message, {
    bool restyle = false,
  }) async {
    final coordinates = message['coordinatesVisible'] != false;
    final weakStatus = message['weakNetworkText'] as String?;
    final geometryChanged =
        coordinates != _remoteCoordinates ||
        (weakStatus == null) != (_remoteWeakStatus == null);
    _remoteCoordinates = coordinates;
    _remoteWeakStatus = weakStatus;
    if (_isWindow && active && (geometryChanged || restyle)) {
      await _applyStyle();
    }
    notifyListeners();
  }

  void _sendSnapshot({bool includePreferences = false}) {
    _host?.send(_snapshot(includePreferences: includePreferences));
  }

  Map<String, dynamic> _snapshot({bool includePreferences = false}) {
    final monitor = _monitor;
    final p = monitor?.position;
    final stop = monitor?.collection.lastDetection;
    return {
      'command': 'snapshot',
      'coordinatesVisible': active,
      'weakNetworkText': weakNetworkText,
      if (includePreferences) 'preferences': _prefs.export(),
      'position': p == null ? null : [p.x, p.y, p.z],
      'status': monitor?.problem?.title ?? monitor?.status ?? '未连接',
      'isError': monitor?.isError ?? false,
      'connectionPhase': monitor?.phase.name,
      'connectionSource': monitor?.connection.source.name,
      'detectionAt':
          monitor?.collection.lastDetectionAt?.millisecondsSinceEpoch,
      'detection': stop == null
          ? null
          : {
              'order': stop.order,
              'x': stop.x,
              'y': stop.y,
              'z': stop.z,
              'direction': stop.direction,
              'distance': stop.distance,
              'heightOffset': stop.heightOffset,
            },
    };
  }

  void _preferencesChanged() => _sendSnapshot(includePreferences: true);

  void _childEnded(CoordinateWindowHost host) {
    if (_host != host) return;
    _host = null;
    active = false;
    _windowFailed = true;
    unawaited(host.close());
    if (!_disposed) notifyListeners();
  }

  bool active = false;

  /// 本次进入悬浮模式的时间，悬浮窗据此在开头几秒显示“按快捷键返回”。
  DateTime? openedAt;

  /// 跟随失败等非致命提示。
  String? warning;
  String? hotkeyWarning;

  bool get followSupported => _locator.isSupported;

  bool get follow => followSupported && _prefs.get(AppPreferences.followGame);

  int get decimals => _prefs.get(AppPreferences.overlayDecimals);

  TargetCoordinate? get target => AppPreferences.target(_prefs);

  Size get baseSize {
    final base = follow ? followSize : normalSize;
    if (!showCoordinates) return Size(base.width, follow ? 30 : 44);
    return Size(
      base.width,
      base.height +
          (target == null ? 0 : _targetExtraHeight) +
          (weakNetworkText == null ? 0 : 24),
    );
  }

  Size get windowSize =>
      baseSize *
      (_prefs.get(AppPreferences.overlayScale) *
          _prefs.get(TfPreferenceKeys.textScale));

  String get hotkeyLabel => AppPreferences.hotkeyOf(_prefs).label;

  late final GlobalHotkey _hotkey = GlobalHotkey(() {
    if (!hotkeyPaused) toggle();
  });

  /// 设置新快捷键时暂停，避免按下旧键误切换。
  bool hotkeyPaused = false;
  final NativeWindow _native = NativeWindow();

  /// Only the display process tracks game-relative placement.
  Timer? _followTimer;
  int _followRevision = 0;
  DateTime _lastFocused = DateTime.now();
  bool? _hidden;
  bool? _onTop;
  bool? _clickThrough;
  bool _busy = false;

  Future<void> initialize() async {
    if (!isSupported || _initialized || _disposed) return;
    _initialized = true;
    await windowManager.ensureInitialized();
    if (_disposed) return;
    if (_isWindow) {
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
    } else {
      _prefs.addListener(_preferencesChanged);
      registerHotkey();
      if (_prefs.get(AppPreferences.overlayVisible)) await open();
    }
  }

  @override
  void onWindowClose() {
    if (_isWindow) _onReturn?.call();
  }

  void registerHotkey() {
    if (!isSupported) return;
    final hotkey = AppPreferences.hotkeyOf(_prefs);
    hotkeyWarning = _hotkey.register(hotkey.key)
        ? null
        : '快捷键 ${hotkey.label} 不可用，请换一个按键';
    notifyListeners();
  }

  Future<void> toggle() => active ? close() : open();

  Future<void> open() async {
    if (!isSupported || active || _disposed) return;
    active = true;
    _windowFailed = false;
    openedAt = DateTime.now();
    notifyListeners();
    if (_isWindow) {
      await _applyStyle();
    } else {
      await _prefs.set(AppPreferences.overlayVisible, true);
      await _syncWindow();
    }
  }

  Future<void> _syncWindow() async {
    if (_disposed || _isWindow || !isSupported) return;
    _syncPending = true;
    if (_busy) return;
    _busy = true;
    try {
      while (_syncPending && !_disposed) {
        _syncPending = false;
        if (!_needsWindow) {
          final host = _host;
          _host = null;
          await host?.close();
          continue;
        }
        if (_windowFailed) continue;
        if (_host != null) {
          _sendSnapshot();
          continue;
        }
        late final CoordinateWindowHost host;
        host = CoordinateWindowHost(
          onExit: () => _childEnded(host),
          onMessage: (message) {
            if (_disposed || _host != host) return;
            if (message['event'] == 'return_main') {
              unawaited(close());
              unawaited(
                windowManager.show().then((_) => windowManager.focus()),
              );
            } else if (message['event'] == 'warning') {
              warning = message['message'] as String?;
              notifyListeners();
            }
          },
        );
        _host = host;
        await host.start(_snapshot(includePreferences: true));
        if (!_disposed && _host == host && _needsWindow) {
          _sendSnapshot(includePreferences: true);
        }
      }
    } catch (error) {
      active = false;
      _windowFailed = true;
      final host = _host;
      _host = null;
      await host?.close();
      warning = '无法打开坐标窗口：$error';
      if (!_disposed) notifyListeners();
    } finally {
      _busy = false;
    }
  }

  Future<void> close() async {
    if (_isWindow) {
      _onReturn?.call();
      return;
    }
    if (!active || _disposed) return;
    active = false;
    warning = null;
    notifyListeners();
    await _prefs.set(AppPreferences.overlayVisible, false);
    await _syncWindow();
  }

  /// 跟随开关或显示位置变化后重新应用样式。
  Future<void> refresh() async {
    if (_isWindow) {
      if (active) await _applyStyle();
    } else {
      _sendSnapshot(includePreferences: true);
    }
    notifyListeners();
  }

  Future<void> _applyStyle() async {
    _stopFollow();
    // Only the separate display process changes its own window styles.
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    // Windows 隐藏标题栏仍保留原生边框；浮窗需要完全无框。
    // close() 的 TitleBarStyle.normal 会恢复普通窗口。
    if (Platform.isWindows) await windowManager.setAsFrameless();
    if (_native.isSupported) _native.configureCoordinateWindow();
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
      if (_native.isSupported) {
        _native.setVisibleWithoutActivation(true);
      } else {
        await windowManager.show(inactive: true);
      }
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
    _native.setRect(
      Rect.fromLTWH(
        rect.left,
        rect.top,
        logical.width * scale,
        logical.height * scale,
      ),
    );
  }

  void _stopFollow() {
    _followRevision++;
    _followTimer?.cancel();
    _followTimer = null;
    _onTop = null;
    _hidden = null;
  }

  Future<void> _setOnTop(bool value) async {
    if (_onTop == value) return;
    _onTop = value;
    if (_native.isSupported) {
      _native.setOnTopWithoutActivation(value);
    } else {
      await windowManager.setAlwaysOnTop(value);
    }
  }

  Future<void> _setHidden(bool value) async {
    if (_hidden == value) return;
    _hidden = value;
    if (_native.isSupported) {
      _native.setVisibleWithoutActivation(!value);
    } else {
      value
          ? await windowManager.hide()
          : await windowManager.show(inactive: true);
    }
  }

  Future<void> _followTick() async {
    if (!active || !follow) return;
    final revision = _followRevision;
    bool stillFollowing() => active && follow && revision == _followRevision;
    final game = _locator.findGameClientRect();
    if (game == null) {
      _setWarning('未找到 ${_locator.targetName} 窗口，坐标窗暂时保持可点击');
      await _setClickThrough(false);
      if (!stillFollowing()) return;
      await _setOnTop(false);
      if (!stillFollowing()) return;
      await _setHidden(false);
      return;
    }
    await _setClickThrough(true);
    if (!stillFollowing()) return;

    final gameForeground = _locator.isGameForeground();
    final selfForeground = _locator.isSelfForeground();
    if (gameForeground) {
      _lastFocused = DateTime.now();
      await _setOnTop(true);
      if (!stillFollowing()) return;
      await _setHidden(false);
    } else if (selfForeground) {
      _lastFocused = DateTime.now();
      await _setOnTop(false);
      if (!stillFollowing()) return;
      await _setHidden(false);
    } else if (DateTime.now().difference(_lastFocused) >= _hideDelay) {
      await _setHidden(true);
    }
    if (!stillFollowing()) return;

    _setWarning(null);
    // 游戏窗口是物理像素。按本窗口所在显示器的缩放换算成逻辑像素计算位置，再换回物理像素摆放，
    // 这样边距和偏移在不同缩放的显示器上观感一致。
    final scale = _native.scale;
    final actual = _native.rect;
    final expected = windowSize * scale;
    if (actual != null &&
        ((actual.width - expected.width).abs() > 2 ||
            (actual.height - expected.height).abs() > 2)) {
      await _resize(windowSize);
      if (!stillFollowing()) return;
    }
    final logical = Rect.fromLTRB(
      game.left / scale,
      game.top / scale,
      game.right / scale,
      game.bottom / scale,
    );
    final position = AppPreferences.position(_prefs);
    final offset = AppPreferences.offset(_prefs, position);
    final target = FollowWindowPlacement.calculate(
      logical,
      windowSize,
      position,
      offset.h,
      offset.v,
    );
    _native.setPosition(target * scale);
  }

  void _setWarning(String? value) {
    if (warning == value) return;
    warning = value;
    notifyListeners();
  }

  /// Close the display process before terminating the main window.
  Future<void> shutdown() async {
    final host = _host;
    _host = null;
    dispose();
    await host?.close();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _monitor?.removeListener(_sendSnapshot);
    _weakNetwork?.removeListener(_weakChanged);
    if (_initialized && !_isWindow) _prefs.removeListener(_preferencesChanged);
    final host = _host;
    _host = null;
    if (host != null) unawaited(host.close());
    _stopFollow();
    windowManager.removeListener(this);
    _hotkey.unregister();
    super.dispose();
  }
}
