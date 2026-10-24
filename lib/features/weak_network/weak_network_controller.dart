import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tf_framework/tf_framework.dart';

import 'package:zipliner_client/shared/logging/app_log.dart';
import 'package:zipliner_client/app/app_preferences.dart';
import 'package:zipliner_client/features/weak_network/network_helper_bridge.dart';
import 'package:zipliner_client/features/weak_network/weak_hotkey.dart';

abstract final class WeakNetworkPrefs {
  static const showOverlay = TfPreferenceKey<bool>(
    'network.showOverlay',
    defaultValue: true,
  );
  static const maximum = TfPreferenceKey<double>(
    'network.maximumSeconds',
    defaultValue: 20,
  );
  static final toggle = TfPreferenceKey<String>(
    'network.toggleHotkey',
    defaultValue: WeakHotkey.toggleDefault.encoded,
  );
  static final release = TfPreferenceKey<String>(
    'network.releaseHotkey',
    defaultValue: WeakHotkey.releaseDefault.encoded,
  );
}

class WeakNetworkController extends ChangeNotifier {
  WeakNetworkController({
    required this.dataDirectory,
    this.preferences,
    NetworkHelperBridge Function()? helperFactory,
    bool? supported,
  }) : supported = supported ?? Platform.isWindows,
       _helperFactory =
           helperFactory ??
           (() => WindowsNetworkHelper(
             dataDirectory,
             targetExecutable:
                 preferences?.get(AppPreferences.gameExecutable) ??
                 'Endfield.exe',
           ));

  final String dataDirectory;
  final TfPreferencesController? preferences;
  final bool supported;
  final NetworkHelperBridge Function() _helperFactory;
  final hotkeys = WeakHotkeys();
  NetworkHelperBridge? _helper;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  bool _disposed = false;
  bool _initialized = false;
  bool _confirmingRisk = false;
  bool _riskAcceptedThisSession = false;
  bool enabled = false;
  bool busy = false;
  bool ready = false;
  bool gameWindowFound = false;
  bool reconnecting = false;
  String? connectionMessage;
  int active = 0;
  int holding = 0;
  int? remaining;
  int releases = 0;
  double elapsed = 0;
  int? _awaitingReleaseRevision;
  Timer? _releaseNotice;
  Timer? _offNotice;
  String? error;
  int driverHelpRevision = 0;
  String? _shutdownError;
  Future<void>? _pendingCleanup;
  bool _shuttingDown = false;

  static const driverHelp =
      '无法加载网络驱动（错误码 2）。\n\n'
      '本工具使用 WinDivert 处理游戏网络流量。WinDivert 可能被安全软件识别为高危工具，'
      '导致驱动文件被隔离或阻止加载。\n\n'
      '请查看安全软件的隔离区、保护历史或“漏洞驱动拦截”记录，'
      '确认拦截的是本工具目录中的 WinDivert64.sys 后，恢复该文件，'
      '并将该文件或本工具所在目录设置为豁免（信任／排除），再重新启动客户端。\n\n'
      '驱动文件位于本工具目录下：\n'
      r'network\_internal\pydivert\windivert_dll\WinDivert64.sys'
      '\n\n仅关闭拦截开关不会自动恢复已隔离的文件。若文件已丢失，设置豁免后请重新完整解压本工具。\n\n'
      '如果仍然失败，请提供安全软件拦截记录及客户端日志。';

  Future<void> _closeHelper(NetworkHelperBridge? helper) {
    if (helper == null) return _pendingCleanup ?? Future<void>.value();
    return _pendingCleanup = _finishHelper(helper);
  }

  Future<void> _finishHelper(NetworkHelperBridge helper) async {
    try {
      await helper.close();
      _shutdownError = null;
    } catch (error) {
      _shutdownError = error.toString();
      AppLog.instance.warn('网络驱动退出清理失败：$error');
    }
  }

  Future<void> shutdown() async {
    _shuttingDown = true;
    _enableRevision++;
    enabled = false;
    ready = false;
    final helper = _helper;
    _helper = null;
    await _closeHelper(helper);
    if (_shutdownError != null) {
      _shuttingDown = false;
      throw StateError(_shutdownError!);
    }
  }

  int _enableRevision = 0;
  int _hotkeyRevision = 0;
  Map<String, dynamic> _positionSample = {'valid': false};
  String coordinateStatus = '请先连接坐标，以便自动确认离开区域。';
  bool get coordinatesConnected => _positionSample['valid'] == true;

  void updatePosition(Map<String, dynamic> sample, String status) {
    final wasConnected = coordinatesConnected;
    _positionSample = sample;
    if (ready) _helper?.send({'command': 'position', 'sample': sample});
    if (coordinateStatus != status || wasConnected != coordinatesConnected) {
      coordinateStatus = status;
      _notify();
    }
  }

  bool get canConnect =>
      supported &&
      ready &&
      !busy &&
      !reconnecting &&
      active == 0 &&
      gameWindowFound;

  String get connectionStatus {
    if (connectionMessage != null) return connectionMessage!;
    if (active > 0) return '已连接';
    if (!ready) {
      return busy ? '正在准备连接，请允许管理员权限。' : '请先打开“开启功能”并允许管理员权限。';
    }
    if (!gameWindowFound) return '未找到游戏窗口，请先打开终末地。';
    return '暂时断开游戏网络 2 秒后恢复，帮助游戏重新连接。';
  }

  void connectGame() {
    if (!canConnect) return;
    reconnecting = true;
    connectionMessage = '正在连接，游戏网络将在 2 秒后恢复…';
    _notify();
    _helper!.send({'command': 'reconnect'});
  }

  String? get overlayStatus {
    if (!showOverlay) return null;
    if (!enabled) return _offNotice?.isActive == true ? '自动弱网：关' : null;
    if (active == 0) return '自动弱网：等待游戏连接';
    if (_releaseNotice?.isActive == true) return '已暂时解除弱网';
    if (holding == 0) return '自动弱网：开';
    return '自动弱网中…${elapsed.floor().clamp(0, maximum.round())}/${maximum.round()}秒';
  }

  void _showOffNotice() {
    _releaseNotice?.cancel();
    _offNotice?.cancel();
    _offNotice = Timer(const Duration(seconds: 1), _notify);
  }

  double get maximum => (preferences?.get(WeakNetworkPrefs.maximum) ?? 20)
      .clamp(10, 30)
      .toDouble();
  bool get showOverlay =>
      preferences?.get(WeakNetworkPrefs.showOverlay) ?? true;

  Future<void> setShowOverlay(bool value) async {
    await preferences?.set(WeakNetworkPrefs.showOverlay, value);
    _notify();
  }

  WeakHotkey get toggleHotkey => WeakHotkey.decode(
    preferences?.get(WeakNetworkPrefs.toggle),
    WeakHotkey.toggleDefault,
  );
  WeakHotkey get releaseHotkey => WeakHotkey.decode(
    preferences?.get(WeakNetworkPrefs.release),
    WeakHotkey.releaseDefault,
  );
  String get status {
    if (!supported) return '弱网功能目前仅支持 Windows';
    if (error != null) return error!;
    if (busy) return '正在准备快捷键，请允许管理员权限';
    if (!enabled) return '功能已关闭，游戏网络正常';
    if (active == 0) return '等待游戏连接；已在游戏内可点击“连接游戏”';
    if (holding > 0) {
      return '自动弱网中${remaining == null ? '' : '，$remaining 秒后暂时解除弱网'}';
    }
    return '自动检测中';
  }

  void initialize() {
    if (_initialized || _disposed) return;
    _initialized = true;
    preferences?.addListener(_settingsChanged);
    hotkeys.onChanged = () {
      if (ready) _configure();
    };
    // Register preferences only. The first explicit enable starts the helper;
    // merely visiting the page must never request elevation.
  }

  Future<void> setTargetExecutable(String executable) async {
    if (busy || reconnecting) throw StateError('请等待当前连接操作结束后再切换窗口。');
    if (preferences?.get(AppPreferences.gameExecutable) == executable) return;
    await setEnabled(false);
    busy = true;
    final helper = _helper;
    _helper = null;
    ready = false;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _closeHelper(helper);
      if (_shutdownError != null) throw StateError(_shutdownError!);
      active = 0;
      holding = 0;
      gameWindowFound = false;
      await preferences?.set(AppPreferences.gameExecutable, executable);
      connectionMessage = null;
    } finally {
      busy = false;
      _notify();
    }
  }

  void _settingsChanged() {
    if (ready) _configure();
    _notify();
  }

  void _configure() => _helper?.send({
    'command': 'configure',
    'maximum': maximum,
    'hotkeys': {
      'toggle': toggleHotkey.helperBinding,
      'release': releaseHotkey.helperBinding,
    },
    'hotkeys_suspended': hotkeys.suspended,
    'hotkey_revision': ++_hotkeyRevision,
  });

  Future<void> setEnabled(
    bool value, {
    Future<bool> Function()? confirmRisk,
  }) async {
    if (!supported || _disposed || _shuttingDown) return;
    if (value && _confirmingRisk) return;
    if (value && !coordinatesConnected) {
      error = '请先在“坐标”页面连接角色，再开启弱网。';
      _notify();
      return;
    }
    if (value && !ready && !busy && !_riskAcceptedThisSession) {
      // Consent is required once per client session. The persisted acknowledgement
      // only skips the first-use countdown; it never bypasses this session's dialog.
      if (confirmRisk == null) return;
      final revision = _enableRevision;
      _confirmingRisk = true;
      bool accepted;
      try {
        accepted = await confirmRisk();
      } finally {
        _confirmingRisk = false;
      }
      if (!accepted ||
          _disposed ||
          _shuttingDown ||
          revision != _enableRevision) {
        return;
      }
      _riskAcceptedThisSession = true;
      if (!coordinatesConnected) {
        error = '坐标连接已断开，请先重新连接角色。';
        _notify();
        return;
      }
    }
    final wasEnabled = enabled;
    enabled = value;
    if (value != wasEnabled) {
      elapsed = 0;
      holding = 0;
      _awaitingReleaseRevision = null;
      _releaseNotice?.cancel();
      if (value) {
        _offNotice?.cancel();
      } else {
        _showOffNotice();
      }
    }
    _enableRevision++;
    error = null;
    if (!value) {
      if (ready) {
        _helper?.send({
          'command': 'enable',
          'enabled': false,
          'request_id': _enableRevision,
        });
      }
      remaining = null;
      _notify();
      return;
    }
    if (busy) {
      _notify();
      return;
    }
    if (ready) {
      _helper!.send({
        'command': 'enable',
        'enabled': true,
        'request_id': _enableRevision,
      });
      _notify();
      return;
    }
    await _prepareHelper();
  }

  Future<void> _prepareHelper() async {
    if (_disposed || _shuttingDown || !supported || ready || busy) return;
    busy = true;
    _notify();
    await _closeHelper(null);
    if (_disposed || _shuttingDown) {
      busy = false;
      return;
    }
    final helper = _helper = _helperFactory();
    _subscription = helper.events.listen(
      _event,
      onError: (Object e) => _failed(e.toString()),
    );
    try {
      await helper.start();
      if (_disposed || _shuttingDown) {
        await _closeHelper(helper);
        return;
      }
      ready = true;
      _configure();
      helper.send({
        'command': 'enable',
        'enabled': enabled,
        'request_id': _enableRevision,
      });
      helper.send({'command': 'position', 'sample': _positionSample});
    } catch (e) {
      ready = false;
      _helper = null;
      _failed(e.toString());
      await _closeHelper(helper);
      await _subscription?.cancel();
    } finally {
      busy = false;
      _notify();
    }
  }

  void _event(Map<String, dynamic> message) {
    if (_disposed) return;
    if (message['event'] == 'hotkey') {
      if (!ready ||
          busy ||
          hotkeys.suspended ||
          message['hotkey_revision'] != _hotkeyRevision) {
        return;
      }
      if (message['action'] == 'toggle') {
        unawaited(setEnabled(!enabled));
      } else if (message['action'] == 'release') {
        releaseBacklog();
      }
      return;
    }
    if (message['event'] == 'error') {
      if (message['winerror'] == 2 && message['phase'] == 'driver_open') {
        driverHelpRevision++;
      }
      ready = false;
      final helper = _helper;
      _helper = null;
      _failed(message['message']?.toString() ?? '网络辅助程序发生错误');
      unawaited(_closeHelper(helper));
      return;
    }
    if (message['event'] == 'reconnect') {
      final phase = message['phase'];
      reconnecting =
          phase == 'blocking' ||
          phase == 'waiting' ||
          (phase == 'restored' && active == 0);
      connectionMessage = switch (phase) {
        'blocking' => '正在连接，游戏网络将在 2 秒后恢复…',
        'restored' => active > 0 ? null : '已恢复网络，等待游戏重新连接…',
        _ => message['message']?.toString() ?? '连接未成功，请重试。',
      };
      _notify();
      return;
    }
    if (message['event'] != 'state') return;
    active = (message['active'] as num?)?.toInt() ?? 0;
    if (active > 0) reconnecting = false;
    gameWindowFound = message['game_window_found'] == true;
    if (!reconnecting && (active > 0 || !gameWindowFound)) {
      connectionMessage = null;
    }
    holding = (message['holding'] as num?)?.toInt() ?? 0;
    releases = (message['release_revision'] as num?)?.toInt() ?? 0;
    if (_awaitingReleaseRevision == null ||
        releases >= _awaitingReleaseRevision!) {
      _awaitingReleaseRevision = null;
      remaining = (message['remaining'] as num?)?.toInt();
      elapsed =
          (message['elapsed'] as num?)?.toDouble() ??
          (remaining == null ? 0 : (maximum - remaining!).clamp(0, maximum));
    }
    _notify();
  }

  void _failed(String message) {
    if (enabled) _showOffNotice();
    enabled = false;
    reconnecting = false;
    active = 0;
    gameWindowFound = false;
    connectionMessage = null;
    error = message;
    AppLog.instance.warn('弱网：$message');
    _notify();
  }

  void releaseBacklog() {
    if (!enabled || !ready) return;
    _helper!.send({'command': 'release_all'});
    elapsed = 0;
    remaining = maximum.ceil();
    _awaitingReleaseRevision = (_awaitingReleaseRevision ?? releases) + 1;
    _releaseNotice?.cancel();
    _releaseNotice = Timer(const Duration(seconds: 1), _notify);
    _notify();
  }

  Future<void> setMaximum(double value) async {
    await preferences?.set(
      WeakNetworkPrefs.maximum,
      value.clamp(10, 30).roundToDouble(),
    );
  }

  Future<void> setHotkey({
    required bool toggle,
    required WeakHotkey binding,
  }) async {
    final other = toggle ? releaseHotkey : toggleHotkey;
    if (binding.sameChord(other)) throw ArgumentError('两个快捷键不能相同');
    await preferences?.set(
      toggle ? WeakNetworkPrefs.toggle : WeakNetworkPrefs.release,
      binding.encoded,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _releaseNotice?.cancel();
    _offNotice?.cancel();
    preferences?.removeListener(_settingsChanged);
    hotkeys.dispose();
    unawaited(_subscription?.cancel());
    unawaited(_closeHelper(_helper));
    super.dispose();
  }
}
