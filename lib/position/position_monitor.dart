import 'dart:async';

import 'package:flutter/foundation.dart';

import '../skland/position_socket.dart';
import '../skland/skland_client.dart';
import '../skland/skland_models.dart';
import '../core/app_log.dart';
import 'capture_recorder.dart';
import 'friendly_error.dart';
import 'token_store.dart';
import 'zipline_matcher.dart';
import 'zipline_realtime_detector.dart';

/// 坐标同步与滑索采集的全部状态。对应原工具的 `PositionMonitorService` + `MainViewModel`
/// + `MainWindow` 中的采集逻辑。
///
/// 与原工具不同：连接中断、网络失败或角色暂时不在线时会自动重连，不需要用户手动点“重新连接”。
class PositionMonitor extends ChangeNotifier {
  PositionMonitor({
    required this.client,
    required this.tokens,
    required this._captureDirectory,
    PositionSocket Function()? socketFactory,
    this.selectedRoleKey,
    this._recordCapture = false,
    this.retryDelays = defaultRetryDelays,
  }) : _socketFactory = socketFactory ?? PositionSocket.new;

  static const defaultRetryDelays = [
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  final SklandClient client;
  final TokenRepository tokens;
  final Future<String> Function() _captureDirectory;
  final PositionSocket Function() _socketFactory;

  /// 自动重连的退避间隔，用完后一直使用最后一项。
  final List<Duration> retryDelays;

  /// 识别到滑索时调用，用于弹出提示。
  void Function(DetectedZiplineStop stop)? onDetection;

  /// 选中角色变化时调用，用于持久化。
  void Function(String key)? onRoleSelected;

  // ---- 连接状态 ----

  String status = '未连接';
  String? warning;
  bool isError = false;
  bool isConnecting = false;
  bool isConnected = false;
  bool hasTokens = true;

  /// 当前的错误说明与补救办法；正常时为 null。
  FriendlyError? problem;

  /// 登录失败的账号（id → 原因），账号管理页据此提示重新登录。
  Map<String, String> failedAccounts = const {};

  /// 下一次自动重连的时间；没有计划重连时为 null。
  DateTime? nextRetryAt;

  /// 当前角色尚未同意森空岛“位置同步”政策，需要用户确认。
  bool policyRequired = false;

  PositionSnapshot? position;
  String? mapId;
  String? levelId;
  List<RoleSession> roles = const [];
  RoleSession? activeRole;
  String? selectedRoleKey;

  int _runId = 0;
  PositionSocket? _socket;
  bool _disposed = false;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  Timer? _retryTicker;

  /// 距离下一次自动重连的秒数。
  int? get retryInSeconds {
    final at = nextRetryAt;
    if (at == null) return null;
    final seconds = (at.difference(DateTime.now()).inMilliseconds / 1000).ceil();
    return seconds < 0 ? 0 : seconds;
  }

  /// 连接；[automatic] 为 true 表示由自动重连触发，不重置退避计数。
  Future<void> start({bool automatic = false}) async {
    final run = ++_runId;
    _cancelRetry();
    if (!automatic) _retryAttempt = 0;
    final previous = _socket;
    _socket = null;
    await previous?.close();

    isConnecting = true;
    isConnected = false;
    status = automatic ? '正在自动重连...' : '正在连接...';
    warning = null;
    isError = false;
    problem = null;
    policyRequired = false;
    position = null;
    mapId = null;
    levelId = null;
    _notify();

    String? failure;
    try {
      await client.syncNetworkTime();
      final stored = await tokens.list();
      if (run != _runId) return;
      hasTokens = stored.isNotEmpty;
      if (stored.isEmpty) {
        roles = const [];
        activeRole = null;
        failedAccounts = const {};
        status = '未登录';
        warning = '登录后才能连接坐标同步';
        return;
      }

      final results = await Future.wait(stored.map(_loadSessions));
      if (run != _runId) return;
      final sessions = [for (final r in results) ...r.sessions];
      failedAccounts = {
        for (final r in results)
          if (r.error != null) r.tokenId: r.error!,
      };
      if (sessions.isEmpty) {
        throw SklandException(failedAccounts.isNotEmpty ? failedAccounts.values.first : '未找到终末地角色');
      }
      if (failedAccounts.isNotEmpty) {
        warning = '有 ${failedAccounts.length} 个账号登录失败（${failedAccounts.values.first}），可在“账号管理”里重新登录';
      }

      roles = sessions;
      final role = sessions.firstWhere((s) => s.key == selectedRoleKey, orElse: () => sessions.first);
      activeRole = role;
      selectedRoleKey = role.key;

      if (!await client.hasAgreedPositionPolicy(role.credential, role.binding, role.region)) {
        if (run != _runId) return;
        policyRequired = true;
        failure = '需要同意森空岛位置同步政策';
        return;
      }

      final websocketToken = await client.getWebSocketToken(role.credential, role.region);
      if (run != _runId) return;
      status = '已连接：${role.displayName}，等待坐标...';
      isConnecting = false;
      AppLog.instance.info('已连接 ${role.displayName}');
      _notify();

      final socket = _socket = _socketFactory();
      final reason = await socket.run(
        websocketToken: websocketToken,
        role: role.binding,
        region: role.region,
        language: client.languageProvider?.call(),
        onSubscribed: () {
          if (run != _runId) return;
          isConnected = true;
          _notify();
        },
        onPosition: (p, map, level) {
          if (run != _runId) return;
          position = p;
          if (map != null && map.trim().isNotEmpty) mapId = map;
          if (level != null && level.trim().isNotEmpty) levelId = level;
          status = '坐标已更新';
          isError = false;
          problem = null;
          _retryAttempt = 0;
          _handlePosition(p);
          _notify();
        },
      );
      if (run == _runId && reason != null) failure = reason;
    } on SklandException catch (e) {
      failure = e.message;
    } catch (e, stack) {
      AppLog.instance.error('连接异常', e, stack);
      failure = '连接失败';
    } finally {
      if (run == _runId) {
        isConnecting = false;
        isConnected = false;
        if (failure != null) _fail(failure);
        _notify();
      }
    }
  }

  void _fail(String reason) {
    status = reason;
    isError = true;
    final explained = problem = FriendlyError.explain(reason);
    AppLog.instance.warn('连接失败：$reason');
    if (explained.retryable) _scheduleRetry(explained);
  }

  void _scheduleRetry(FriendlyError problem) {
    final delay = problem.retryDelay ?? retryDelays[_retryAttempt.clamp(0, retryDelays.length - 1)];
    _retryAttempt++;
    nextRetryAt = DateTime.now().add(delay);
    _retryTicker = Timer.periodic(const Duration(seconds: 1), (_) => _notify());
    _retryTimer = Timer(delay, () {
      _cancelRetry();
      start(automatic: true);
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryTicker?.cancel();
    _retryTicker = null;
    nextRetryAt = null;
  }

  Future<({String tokenId, List<RoleSession> sessions, String? error})> _loadSessions(StoredToken token) async {
    try {
      final credential = await client.login(token.token, token.region);
      final bindings = await client.getRoleBindings(credential, token.region);
      final label = bindings.map((b) => b.displayName).join('、');
      if (label.isNotEmpty) unawaited(tokens.setLabel(token.id, label));
      return (
        tokenId: token.id,
        sessions: [
          for (final b in bindings)
            RoleSession(tokenId: token.id, region: token.region, credential: credential, binding: b),
        ],
        error: null,
      );
    } on SklandException catch (e) {
      return (tokenId: token.id, sessions: const <RoleSession>[], error: e.message);
    } catch (_) {
      return (tokenId: token.id, sessions: const <RoleSession>[], error: '加载失败');
    }
  }

  /// 用户确认后代为同意位置同步政策并重新连接。
  Future<void> agreePolicyAndConnect() async {
    final role = activeRole;
    if (role == null) return;
    try {
      await client.agreePositionPolicy(role.credential, role.binding, role.region);
      AppLog.instance.info('已同意位置同步政策 ${role.displayName}');
    } on SklandException catch (e) {
      _fail(e.message);
      _notify();
      return;
    }
    await start();
  }

  Future<void> switchRole(String key) async {
    selectedRoleKey = key;
    onRoleSelected?.call(key);
    await start();
  }

  Future<void> disconnect() async {
    _runId++;
    _cancelRetry();
    final socket = _socket;
    _socket = null;
    await socket?.close();
    isConnecting = false;
    isConnected = false;
    status = '已断开';
    isError = false;
    problem = null;
    _notify();
  }

  // ---- 滑索采集 ----

  bool isCapturing = false;
  bool isLoadingMarks = false;
  List<ZiplineMark>? captureMarks;
  ZiplineRealtimeDetector? detector;
  ZiplineLookupResult? lookupResult;
  String? manualResultText;
  PositionCaptureRecorder? _recorder;
  String? _marksAttemptKey;
  bool _recordCapture;

  bool get recordCapture => _recordCapture;

  set recordCapture(bool value) {
    _recordCapture = value;
    _notify();
  }

  bool get hasDetections => detector?.detectedStops.isNotEmpty ?? false;

  String get captureStatusText {
    final recorder = _recorder;
    if (isCapturing) {
      return recorder != null && recorder.isRecording
          ? '采集中：样本 ${recorder.sampleCount}，目录 ${recorder.currentSessionDirectory}。停在滑索上等待识别，也可以手动获取当前滑索。'
          : '采集中：未记录文件。停在滑索上等待识别，也可以手动获取当前滑索。';
    }
    return _recordCapture ? '未采集。开始采集后会记录 positions、marks、detections 文件。' : '未采集。当前不会记录文件，只保留本次识别结果用于复制。';
  }

  String? get realtimeText {
    if (!isCapturing && !hasDetections) return null;
    final d = detector;
    if (d == null) return '实时识别：等待滑索数据';
    return '实时识别：${d.detectedStops.length} 个\n${d.resultText()}';
  }

  Future<void> startCapture() async {
    isCapturing = true;
    if (_recordCapture) {
      (_recorder ??= PositionCaptureRecorder(await _captureDirectory())).start(DateTime.now());
    } else {
      _recorder?.stop();
    }
    captureMarks = null;
    detector = null;
    lookupResult = null;
    manualResultText = null;
    _marksAttemptKey = null;
    warning = '已开始采集，正在获取当前地图滑索数据...';
    _notify();
    await _loadCaptureMarks();
  }

  void stopCapture() {
    isCapturing = false;
    _recorder?.stop();
    warning = '已停止采集';
    _notify();
  }

  bool get _hasCapturePrerequisites => mapId != null && activeRole != null;

  Future<void> _loadCaptureMarks() async {
    final role = activeRole;
    final map = mapId;
    if (map == null || role == null) {
      warning = '已开始采集；等待地图、登录和角色信息后再获取滑索数据';
      _notify();
      return;
    }
    _marksAttemptKey = '${role.key}|$map';
    isLoadingMarks = true;
    _notify();
    try {
      final marks = await client.getZiplineMarks(role.credential, map, role.binding, role.region);
      captureMarks = marks;
      if (_recorder?.isRecording ?? false) _recorder!.writeMarks(marks);
      detector = ZiplineRealtimeDetector(marks);
      warning = '已获取滑索数据：${marks.length} 个，停在滑索上等待识别';
    } on SklandException catch (e) {
      warning = e.message;
    } catch (_) {
      warning = '获取采集用滑索数据失败';
    } finally {
      isLoadingMarks = false;
      _notify();
    }
  }

  void _handlePosition(PositionSnapshot p) {
    final recorder = _recorder;
    if (recorder != null && recorder.isRecording) recorder.record(p, DateTime.now());
    if (!isCapturing) return;

    final d = detector;
    if (d == null) {
      final key = '${activeRole?.key}|$mapId';
      if (!isLoadingMarks && _hasCapturePrerequisites && _marksAttemptKey != key) unawaited(_loadCaptureMarks());
      return;
    }
    final stop = d.update(p);
    if (stop != null) _reportDetection(stop);
  }

  void _reportDetection(DetectedZiplineStop stop) {
    final recorder = _recorder;
    if (recorder != null && recorder.isRecording) recorder.writeDetection(stop, DateTime.now());
    warning = '已识别第 ${stop.order} 个滑索：${stop.label}';
    lastDetection = stop;
    lastDetectionAt = DateTime.now();
    onDetection?.call(stop);
  }

  DetectedZiplineStop? lastDetection;
  DateTime? lastDetectionAt;

  /// 手动查找当前位置 3 米内的滑索，并加入采集结果。
  Future<void> manualDetect() async {
    final p = position;
    if (p == null) return _setManual('缺少当前位置，连接成功并获取坐标后再试');
    if (mapId == null) return _setManual('缺少当前地图 ID，等待坐标同步后再试');
    final role = activeRole;
    if (role == null) return _setManual('缺少登录或角色信息，连接成功后再试');

    _setManual('正在获取滑索坐标...');
    try {
      final marks = captureMarks ??= await client.getZiplineMarks(role.credential, mapId!, role.binding, role.region);
      final result = ZiplineMatcher.findNearest(p, marks);
      lookupResult = result;
      manualResultText = result.found ? result.toTupleText() : result.message;
      if (result.found) {
        final stop = (detector ??= ZiplineRealtimeDetector(marks)).addManual(p);
        if (stop != null) _reportDetection(stop);
      }
      _notify();
    } on SklandException catch (e) {
      _setManual(e.message);
    } catch (_) {
      _setManual('获取滑索坐标失败');
    }
  }

  void _setManual(String text) {
    manualResultText = text;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _runId++;
    _cancelRetry();
    _socket?.close();
    _recorder?.stop();
    super.dispose();
  }
}
