import 'dart:async';

import 'package:flutter/foundation.dart';

import '../skland/position_socket.dart';
import '../skland/skland_client.dart';
import '../skland/skland_models.dart';
import '../core/app_log.dart';
import '../core/api_exception.dart';
import '../account/client_accounts.dart';
import '../account/cloud_position_source.dart';
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
    this.accounts,
    this.gameWindowPresent,
    this.gameWindowName,
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
  final ClientAccounts? accounts;
  final bool Function()? gameWindowPresent;
  final String Function()? gameWindowName;
  String get _openGamePrompt =>
      gameWindowName == null ||
          gameWindowName!().toLowerCase() == 'endfield.exe'
      ? '请打开终末地游戏'
      : '请打开所选游戏窗口（${gameWindowName!()}）';
  Timer? _gameWatch;
  bool _waitingForGame = false;
  DateTime? _gameDetectedAt;
  bool? _lastGameWindow;
  bool _autoRetryWanted = false;
  CloudPositionSource? _cloud;
  Timer? _recovery;
  String sourceLabel = '森空岛直连';
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
  int positionRevision = 0;
  DateTime? positionReceivedAt;
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
    final seconds = (at.difference(DateTime.now()).inMilliseconds / 1000)
        .ceil();
    return seconds < 0 ? 0 : seconds;
  }

  /// 连接；[automatic] 为 true 表示由自动重连触发，不重置退避计数。
  Future<void> start({bool automatic = false}) async {
    if (_disposed) return;
    if (gameWindowPresent != null) {
      _gameWatch ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_autoRetryWanted || isConnecting || isConnected) {
          _readGameWindow();
          return;
        }
        final wasWaiting = _waitingForGame;
        if (_checkGameWindow() && wasWaiting) unawaited(start(automatic: true));
      });
      _readGameWindow();
      if (automatic && !_checkGameWindow()) return;
    }
    _autoRetryWanted = false;
    final run = ++_runId;
    // Block repeated clicks while the previous transport is being closed.
    isConnecting = true;
    _notify();
    _recovery?.cancel();
    _cancelRetry();
    final previousCloud = _cloud;
    _cloud = null;
    await previousCloud?.close();
    if (!automatic) _retryAttempt = 0;
    final previous = _socket;
    _socket = null;
    await previous?.close();
    if (run != _runId) return;

    isConnecting = true;
    isConnected = false;
    status = automatic ? '正在自动重连...' : '正在连接...';
    warning = null;
    isError = false;
    problem = null;
    policyRequired = false;
    sourceLabel = accounts?.isCloud == true && !accounts!.forceDirect
        ? 'Zipliner 共享定位'
        : '森空岛直连';
    position = null;
    positionReceivedAt = null;
    captureMarks = null;
    detector = null;
    _marksAttemptKey = null;
    mapId = null;
    levelId = null;
    _notify();

    String? failure;
    try {
      final profile = accounts;
      if (profile != null) selectedRoleKey = await profile.selectedRole();
      if (run != _runId) return;
      RoleSession? cloudRole;
      if (profile?.isCloud == true && !profile!.forceDirect) {
        try {
          await profile.refreshBindings();
        } on ApiException catch (e) {
          if (e.isUnauthorized || e.isForbidden || profile.gameRoles.isEmpty) {
            rethrow;
          }
        }
        if (run != _runId) return;
        roles = profile.cloudSessions();
        selectedRoleKey = await profile.selectedRole();
        if (run != _runId) return;
        hasTokens = roles.isNotEmpty;
        if (roles.isEmpty) throw const SklandException('请先在账号管理中绑定游戏账号和角色');
        cloudRole = roles.firstWhere(
          (r) => r.key == selectedRoleKey,
          orElse: () => roles.first,
        );
        activeRole = cloudRole;
        selectedRoleKey = cloudRole.key;
        sourceLabel = 'Zipliner 共享定位';
        final source = _cloud = CloudPositionSource(profile.api);
        final reason = await source.run(
          role: cloudRole,
          onConnection: (connected) {
            if (run != _runId) return;
            isConnected = connected;
            // Waiting for an upstream recovery is not an active handshake.
            isConnecting = false;
            if (!connected) {
              positionReceivedAt = null;
              isError = true;
              status = problem?.title ?? '共享定位暂时不可用，正在等待恢复';
              problem ??= FriendlyError(
                title: status,
                hint: '服务端未提供具体原因。工具会继续等待坐标，也可以手动重新连接。',
                action: FixAction.reconnect,
                retryable: true,
                raw: status,
              );
            }
            _notify();
          },
          onCachedPosition: (p, map, level) {
            if (run != _runId || position != null) return;
            position = p;
            mapId = map;
            levelId = level;
            positionReceivedAt = null;
            status = '已显示上次坐标，等待实时更新';
            _notify();
          },
          onPosition: (p, map, level, observed) =>
              _acceptPosition(run, p, map, level, observed),
          onUpstreamError: (message) {
            if (run != _runId) return;
            isConnected = false;
            isConnecting = false;
            isError = true;
            positionReceivedAt = null;
            status = message;
            problem = FriendlyError.explain(message);
            _notify();
          },
        );
        if (run != _runId || reason == null) return;
        if (!reason.allowFallback) {
          throw SklandException(reason.message);
        }
        sourceLabel = '森空岛直连兜底';
        position = null;
        positionReceivedAt = null;
        mapId = null;
        levelId = null;
        isConnected = false;
        _notify();
      }
      await client.syncNetworkTime();
      final repository = tokens;
      final stored = await repository.list();
      if (run != _runId) return;
      hasTokens = stored.isNotEmpty;
      if (stored.isEmpty) {
        if (cloudRole != null) {
          throw const SklandException('本机档案中没有当前角色的凭据，请在账号面板中添加或选用本机账号');
        }
        roles = const [];
        activeRole = null;
        failedAccounts = const {};
        status = '未登录';
        warning = '登录后才能连接坐标同步';
        return;
      }

      final results = await Future.wait(
        stored.map((t) => _loadSessions(t, repository)),
      );
      if (run != _runId) return;
      final sessions = [for (final r in results) ...r.sessions];
      failedAccounts = {
        for (final r in results)
          if (r.error != null) r.tokenId: r.error!,
      };
      if (sessions.isEmpty) {
        throw SklandException(
          failedAccounts.isNotEmpty ? failedAccounts.values.first : '未找到终末地角色',
        );
      }
      if (failedAccounts.isNotEmpty) {
        warning =
            '有 ${failedAccounts.length} 个账号登录失败（${failedAccounts.values.first}），可在“账号管理”里重新登录';
      }

      if (cloudRole == null) roles = sessions;
      final matching = cloudRole == null
          ? sessions
          : sessions
                .where(
                  (r) =>
                      r.region == cloudRole!.region &&
                      r.binding.roleId == cloudRole.binding.roleId &&
                      r.binding.serverId == cloudRole.binding.serverId,
                )
                .toList();
      if (matching.isEmpty) {
        throw const SklandException('本机档案中没有匹配当前角色的账号，请在账号面板中添加或选用本机账号');
      }
      final localDefaultAccount = cloudRole == null
          ? await profile?.guest.defaultAccount()
          : null;
      if (run != _runId) return;
      final role = matching.firstWhere(
        (s) => s.key == selectedRoleKey,
        orElse: () => matching.firstWhere(
          (s) => s.tokenId == localDefaultAccount,
          orElse: () => matching.first,
        ),
      );
      activeRole = role;
      selectedRoleKey = cloudRole?.key ?? role.key;

      if (!await client.hasAgreedPositionPolicy(
        role.credential,
        role.binding,
        role.region,
      )) {
        if (run != _runId) return;
        policyRequired = true;
        failure = '需要同意森空岛位置同步政策';
        return;
      }

      final websocketToken = await client.getWebSocketToken(
        role.credential,
        role.region,
      );
      if (run != _runId) return;
      status = '已连接：${role.displayName}，等待坐标...';
      isConnecting = false;
      AppLog.instance.info('已连接 ${role.displayName}');
      _notify();

      final socket = _socket = _socketFactory();
      if (profile?.isCloud == true && !profile!.forceDirect) {
        _scheduleCloudRecovery(run);
      }
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
          _acceptPosition(run, p, map, level, DateTime.now());
        },
      );
      if (run == _runId && reason != null) failure = reason;
    } on ApiException catch (e) {
      failure = e.message;
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
    _autoRetryWanted = explained.retryable;
    if (explained.retryable && _checkGameWindow()) _scheduleRetry(explained);
  }

  bool _readGameWindow() {
    final present = gameWindowPresent?.call() ?? true;
    if (present && _lastGameWindow == false) _gameDetectedAt = DateTime.now();
    if (!present) _gameDetectedAt = null;
    _lastGameWindow = present;
    return present;
  }

  bool _checkGameWindow() {
    if (_disposed) return false;
    if (gameWindowPresent == null) return true;
    if (!_readGameWindow()) {
      if (!_waitingForGame || nextRetryAt != null) {
        _runId++;
        _cancelRetry();
        _recovery?.cancel();
        final socket = _socket;
        final cloud = _cloud;
        _socket = null;
        _cloud = null;
        unawaited(socket?.close());
        unawaited(cloud?.close());
        _waitingForGame = true;
        _gameDetectedAt = null;
        positionReceivedAt = null;
        isConnected = false;
        isConnecting = false;
        isError = false;
        problem = null;
        status = _openGamePrompt;
        warning = null;
        _notify();
      }
      if (status != _openGamePrompt) {
        status = _openGamePrompt;
        isError = false;
        problem = null;
        _notify();
      }
      return false;
    }
    if (!_waitingForGame && _gameDetectedAt == null) return true;
    _waitingForGame = true;
    _gameDetectedAt ??= DateTime.now();
    nextRetryAt = _gameDetectedAt!.add(const Duration(seconds: 30));
    if (DateTime.now().isBefore(nextRetryAt!)) {
      status = '已检测到终末地游戏，等待启动完成';
      _notify();
      return false;
    }
    _waitingForGame = false;
    _gameDetectedAt = null;
    nextRetryAt = null;
    return true;
  }

  void _stopGameWatch() {
    _gameWatch?.cancel();
    _gameWatch = null;
    _autoRetryWanted = false;
  }

  void _acceptPosition(
    int run,
    PositionSnapshot p,
    String? map,
    String? level,
    DateTime observed,
  ) {
    if (run != _runId) return;
    position = p;
    positionRevision++;
    positionReceivedAt = observed;
    if (map != null && map.isNotEmpty) {
      if (map != mapId) {
        levelId = null;
        captureMarks = null;
        detector = null;
      }
      mapId = map;
    }
    if (level != null && level.isNotEmpty) levelId = level;
    status = '坐标已更新';
    isConnected = true;
    isConnecting = false;
    isError = false;
    problem = null;
    _retryAttempt = 0;
    _handlePosition(p);
    _notify();
  }

  void _scheduleCloudRecovery(int run) {
    var successes = 0;
    var checking = false;
    _recovery = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (checking || run != _runId) return;
      checking = true;
      try {
        await accounts!.api.get('/api/account/session', auth: true);
        if (run == _runId && ++successes >= 2) {
          if (gameWindowPresent != null &&
              (!_readGameWindow() ||
                  (_gameDetectedAt != null &&
                      DateTime.now().isBefore(
                        _gameDetectedAt!.add(const Duration(seconds: 30)),
                      )))) {
            return;
          }
          _recovery?.cancel();
          unawaited(start(automatic: true));
        }
      } catch (_) {
        successes = 0;
      } finally {
        checking = false;
      }
    });
  }

  Future<List<ZiplineMark>> _marks(RoleSession role, String map) async {
    if (role.hasLocalCredential) {
      return client.getZiplineMarks(
        role.credential,
        map,
        role.binding,
        role.region,
      );
    }
    final data = await accounts!.api.get(
      '/api/account/ziplines',
      auth: true,
      query: {
        'mapId': map,
        'roleId': role.binding.roleId,
        'serverId': role.binding.serverId,
      },
    );
    return [
      for (final item in (data as Map)['items'] as List)
        ZiplineMark(
          (item['x'] as num).toDouble(),
          (item['y'] as num).toDouble(),
          (item['z'] as num).toDouble(),
        ),
    ];
  }

  void _scheduleRetry(FriendlyError problem) {
    final delay =
        problem.retryDelay ??
        retryDelays[_retryAttempt.clamp(0, retryDelays.length - 1)];
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

  Future<({String tokenId, List<RoleSession> sessions, String? error})>
  _loadSessions(StoredToken token, TokenRepository repository) async {
    try {
      final credential = await client.login(token.token, token.region);
      final bindings = await client.getRoleBindings(credential, token.region);
      final label = bindings.map((b) => b.displayName).join('、');
      if (label.isNotEmpty) unawaited(repository.setLabel(token.id, label));
      return (
        tokenId: token.id,
        sessions: [
          for (final b in bindings)
            RoleSession(
              tokenId: token.id,
              region: token.region,
              credential: credential,
              binding: b,
            ),
        ],
        error: null,
      );
    } on SklandException catch (e) {
      return (
        tokenId: token.id,
        sessions: const <RoleSession>[],
        error: e.message,
      );
    } catch (_) {
      return (
        tokenId: token.id,
        sessions: const <RoleSession>[],
        error: '加载失败',
      );
    }
  }

  /// 用户确认后代为同意位置同步政策并重新连接。
  Future<void> agreePolicyAndConnect() async {
    final role = activeRole;
    if (role == null) return;
    try {
      await client.agreePositionPolicy(
        role.credential,
        role.binding,
        role.region,
      );
      AppLog.instance.info('已同意位置同步政策 ${role.displayName}');
    } on SklandException catch (e) {
      _fail(e.message);
      _notify();
      return;
    }
    await start();
  }

  Future<void> switchRole(String key) async {
    await accounts?.beforeIdentityChange?.call();
    selectedRoleKey = key;
    await accounts?.selectRole(key);
    onRoleSelected?.call(key);
    await start();
  }

  Future<void> disconnect() async {
    _stopGameWatch();
    _runId++;
    _recovery?.cancel();
    final cloud = _cloud;
    _cloud = null;
    _cancelRetry();
    final socket = _socket;
    _socket = null;
    await Future.wait<void>([
      if (cloud != null) cloud.close(),
      if (socket != null) socket.close(),
    ]);
    isConnecting = false;
    isConnected = false;
    position = null;
    positionReceivedAt = null;
    mapId = null;
    levelId = null;
    captureMarks = null;
    detector = null;
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
    return _recordCapture
        ? '未采集。开始采集后会记录 positions、marks、detections 文件。'
        : '未采集。当前不会记录文件，只保留本次识别结果用于复制。';
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
      (_recorder ??= PositionCaptureRecorder(
        await _captureDirectory(),
      )).start(DateTime.now());
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
    final run = _runId;
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
      final marks = await _marks(role, map);
      if (run != _runId) return;
      captureMarks = marks;
      if (_recorder?.isRecording ?? false) _recorder!.writeMarks(marks);
      detector = ZiplineRealtimeDetector(marks);
      warning = '已获取滑索数据：${marks.length} 个，停在滑索上等待识别';
    } on SklandException catch (e) {
      warning = e.message;
    } catch (_) {
      warning = '获取采集用滑索数据失败';
    } finally {
      if (run == _runId) {
        isLoadingMarks = false;
        _notify();
      }
    }
  }

  void _handlePosition(PositionSnapshot p) {
    final recorder = _recorder;
    if (recorder != null && recorder.isRecording) {
      recorder.record(p, DateTime.now());
    }
    if (!isCapturing) return;

    final d = detector;
    if (d == null) {
      final key = '${activeRole?.key}|$mapId';
      if (!isLoadingMarks &&
          _hasCapturePrerequisites &&
          _marksAttemptKey != key) {
        unawaited(_loadCaptureMarks());
      }
      return;
    }
    final stop = d.update(p);
    if (stop != null) _reportDetection(stop);
  }

  void _reportDetection(DetectedZiplineStop stop) {
    final recorder = _recorder;
    if (recorder != null && recorder.isRecording) {
      recorder.writeDetection(stop, DateTime.now());
    }
    warning = '已识别第 ${stop.order} 个滑索：${stop.label}';
    lastDetection = stop;
    lastDetectionAt = DateTime.now();
    onDetection?.call(stop);
  }

  DetectedZiplineStop? lastDetection;
  DateTime? lastDetectionAt;

  /// 手动查找当前位置 3 米内的滑索，并加入采集结果。
  Future<void> manualDetect() async {
    final run = _runId;
    final p = position;
    if (p == null) return _setManual('缺少当前位置，连接成功并获取坐标后再试');
    if (mapId == null) return _setManual('缺少当前地图 ID，等待坐标同步后再试');
    final role = activeRole;
    if (role == null) return _setManual('缺少登录或角色信息，连接成功后再试');

    _setManual('正在获取滑索坐标...');
    try {
      final marks = captureMarks ?? await _marks(role, mapId!);
      if (run != _runId) return;
      captureMarks = marks;
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
    _stopGameWatch();
    _disposed = true;
    _runId++;
    _cancelRetry();
    _recovery?.cancel();
    _cloud?.close();
    _socket?.close();
    _recorder?.stop();
    super.dispose();
  }
}
