import 'package:zipliner_client/features/collection/collection_controller.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:zipliner_client/integrations/skland/position_socket.dart';
import 'package:zipliner_client/integrations/skland/skland_client.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';
import 'package:zipliner_client/shared/logging/app_log.dart';
import 'package:zipliner_client/shared/http/api_exception.dart';
import 'package:zipliner_client/features/accounts/application/client_accounts.dart';
import 'package:zipliner_client/features/position/connections/desktop_position_publisher.dart';

import 'direct_account_sessions.dart';

import 'package:zipliner_client/features/position/models/position_connection.dart';
import 'package:zipliner_client/features/position/application/position_timing.dart';
import 'package:zipliner_client/features/position/models/friendly_error.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';

/// Owns position connections, selected roles and recovery.
/// Collection receives coordinates through [collection] without owning the connection.
class PositionMonitor extends ChangeNotifier {
  PositionMonitor({
    required this.client,
    required this.tokens,
    required this._captureDirectory,
    PositionSocket Function()? socketFactory,
    this.selectedRoleKey,
    bool recordCapture = false,
    this.accounts,
    this.gameWindowPresent,
    this.gameWindowName,
    this.retryDelays = defaultRetryDelays,
  }) : _socketFactory = socketFactory ?? PositionSocket.new {
    collection = CollectionController(
      readContext: () => CollectionContext(
        revision: _runId,
        role: activeRole,
        mapId: mapId,
        position: position,
      ),
      loadMarks: _marks,
      captureDirectory: _captureDirectory,
      setWarning: (value) => warning = value,
      onChanged: _notify,
      recordCapture: recordCapture,
    );
  }

  late final CollectionController collection;

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
  DesktopPositionPublisher? _publisher;
  bool get syncedToWebsite =>
      isConnected && _publisher?.syncedToWebsite == true;
  late final sessions = DirectAccountSessions(client, accounts);
  String get sourceLabel => switch (connection.source) {
    PositionSource.direct => '森空岛直连',
    PositionSource.shared => 'Zipliner 共享定位',
  };
  final Future<String> Function() _captureDirectory;
  final PositionSocket Function() _socketFactory;

  /// 自动重连的退避间隔，用完后一直使用最后一项。
  final List<Duration> retryDelays;

  /// 选中角色变化时调用，用于持久化。
  void Function(String key)? onRoleSelected;

  // ---- 连接状态 ----

  String status = '未连接';
  String? warning;
  final connection = PositionConnection();
  bool get isError => connection.error;
  bool get isConnecting => connection.connecting;
  bool get isConnected => connection.connected;
  PositionPhase get phase => connection.phase;
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
  PositionTiming? _timing;
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
    _timing?.flush();
    _timing = PositionTiming('monitor')..stage('start');
    // Block repeated clicks while the previous transport is being closed.
    connection.transition(PositionPhase.connecting);
    _notify();
    _cancelRetry();
    _publisher?.pause();
    if (!automatic) _retryAttempt = 0;
    final previous = _socket;
    _socket = null;
    await previous?.close();
    if (run != _runId) return;
    _timing?.stage('previous_transport_closed');

    connection.transition(PositionPhase.connecting);
    status = automatic ? '正在自动重连...' : '正在连接...';
    warning = null;
    problem = null;
    policyRequired = false;
    connection.source = PositionSource.direct;
    position = null;
    positionReceivedAt = null;
    collection.clearMap(resetAttempt: true);
    mapId = null;
    levelId = null;
    _notify();

    String? failure;
    bool? retryable;
    try {
      final profile = accounts;
      if (profile != null) selectedRoleKey = await profile.selectedRole();
      if (run != _runId) return;
      RoleSession role;
      if (profile?.isCloud == true && !profile!.useLocalCredentials) {
        if (profile.gameRoles.isEmpty) await profile.refreshBindings();
        if (run != _runId) return;
        roles = profile.cloudSessions();
        hasTokens = roles.isNotEmpty;
        if (roles.isEmpty) throw const SklandException('请先在账号管理中绑定游戏账号和角色');
        final selected = roles.firstWhere(
          (r) => r.key == selectedRoleKey,
          orElse: () => roles.first,
        );
        role = await sessions.cloud(selected);
      } else {
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
        final results = await Future.wait(
          stored.map((t) => _loadSessions(t, tokens)),
        );
        if (run != _runId) return;
        roles = [for (final result in results) ...result.sessions];
        failedAccounts = {
          for (final result in results)
            if (result.error != null) result.tokenId: result.error!,
        };
        if (roles.isEmpty) {
          throw SklandException(
            failedAccounts.isNotEmpty
                ? failedAccounts.values.first
                : '未找到终末地角色',
          );
        }
        final defaultAccount = await profile?.guest.defaultAccount();
        role = roles.firstWhere(
          (r) => r.key == selectedRoleKey,
          orElse: () => roles.firstWhere(
            (r) => r.tokenId == defaultAccount,
            orElse: () => roles.first,
          ),
        );
        if (failedAccounts.isNotEmpty) {
          warning = '部分账号登录失败，请在账号管理中重新登录';
        }
      }
      if (run != _runId) return;
      activeRole = role;
      selectedRoleKey = role.key;
      _timing?.stage('direct_account_ready');
      if (!await sessions.policyAgreed(role)) {
        if (run != _runId) return;
        policyRequired = true;
        failure = '需要同意森空岛位置同步政策';
        return;
      }
      final websocketToken = await sessions.socketToken(role);
      if (run != _runId) return;
      _timing?.stage('official_token_ready');
      final bound = profile?.isCloud == true
          ? profile!
                .cloudSessions()
                .where(
                  (candidate) =>
                      candidate.region == role.region &&
                      candidate.binding.roleId == role.binding.roleId &&
                      candidate.binding.serverId == role.binding.serverId,
                )
                .firstOrNull
          : null;
      if (bound == null || _publisher?.matches(bound) == false) {
        final previousPublisher = _publisher;
        _publisher = null;
        if (previousPublisher != null) {
          unawaited(previousPublisher.close(handoff: true));
        }
      }
      if (bound != null && _publisher == null) {
        _publisher = DesktopPositionPublisher(
          profile!.api,
          bound,
          onSyncChanged: _notify,
        )..start();
      }
      status = '已连接：${role.displayName}，等待坐标...';
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
          connection.transition(PositionPhase.connected);
          _notify();
        },
        onPosition: (p, map, level) {
          _acceptPosition(run, p, map, level, DateTime.now());
        },
      );
      if (run == _runId && reason != null) {
        failure = reason;
        if (RegExp(r'^服务器关闭连接（code="?10002"?）：').hasMatch(reason)) {
          sessions.forgetSocketToken(role);
          retryable = true;
        }
      }
    } on ApiException catch (e) {
      failure = e.message;
    } on SklandException catch (e) {
      failure = e.message;
    } catch (e, stack) {
      AppLog.instance.error('连接异常', e, stack);
      failure = '连接失败';
    } finally {
      if (run == _runId) {
        final publisher = _publisher;
        _publisher = null;
        if (publisher != null) unawaited(publisher.close());
        connection.transition(PositionPhase.idle);
        if (failure != null) _fail(failure, retryable: retryable);
        _notify();
      }
    }
  }

  void _fail(String reason, {bool? retryable}) {
    status = reason;
    connection.transition(PositionPhase.failed);
    final original = FriendlyError.explain(reason);
    final explained = problem = retryable == null
        ? original
        : FriendlyError(
            title: original.title,
            hint: original.hint,
            action: original.action,
            retryable: retryable,
            retryDelay: original.retryDelay,
            raw: reason,
          );
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
        final socket = _socket;
        final publisher = _publisher;
        _socket = null;
        _publisher = null;
        unawaited(socket?.close());
        if (publisher != null) unawaited(publisher.close());
        connection.transition(PositionPhase.waitingForGame);
        _waitingForGame = true;
        _gameDetectedAt = null;
        positionReceivedAt = null;
        problem = null;
        status = _openGamePrompt;
        warning = null;
        _notify();
      }
      if (status != _openGamePrompt) {
        status = _openGamePrompt;
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
      connection.transition(PositionPhase.waitingForGame);
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
    final received = _timing?.begin();
    position = p;
    positionRevision++;
    positionReceivedAt = observed;
    if (map != null && map.isNotEmpty) {
      if (map != mapId) {
        levelId = null;
        collection.clearMap();
      }
      mapId = map;
    }
    if (level != null && level.isNotEmpty) levelId = level;
    _publisher?.offer(p, mapId, levelId);
    status = '坐标已更新';
    connection.transition(PositionPhase.connected);
    problem = null;
    _retryAttempt = 0;
    collection.acceptPosition(p);
    _notify();
    if (received != null) _timing?.end(received);
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
      final loaded = await sessions.local(token);
      final label = loaded.map((r) => r.displayName).join('、');
      if (label.isNotEmpty) unawaited(repository.setLabel(token.id, label));
      return (tokenId: token.id, sessions: loaded, error: null);
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
      sessions.markPolicyAgreed(role);
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
    _timing?.flush();
    _timing = null;
    _runId++;
    final publisher = _publisher;
    _publisher = null;
    _cancelRetry();
    final socket = _socket;
    _socket = null;
    await socket?.close();
    await publisher?.close(handoff: true);
    connection.transition(PositionPhase.stopped);
    position = null;
    positionReceivedAt = null;
    mapId = null;
    levelId = null;
    collection.clearMap();
    status = '已断开';
    problem = null;
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
    final socket = _socket;
    final publisher = _publisher;
    unawaited(() async {
      await socket?.close();
      await publisher?.close(handoff: true);
    }());
    collection.dispose();
    super.dispose();
  }
}
