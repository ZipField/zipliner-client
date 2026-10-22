import 'dart:async';

import 'package:signalr_netcore/signalr_client.dart';
import 'package:signalr_netcore/ihub_protocol.dart';

import '../core/api_client.dart';
import '../core/app_log.dart';
import '../skland/skland_models.dart';

class CloudPositionFailure implements Exception {
  const CloudPositionFailure(this.message, {this.allowFallback = false});
  final String message;
  final bool allowFallback;
  @override
  String toString() => message;
}

/// One consumer lease. Closing it must never stop the other consumers.
class CloudPositionSource {
  CloudPositionSource(this.api);
  final ApiClient api;
  HubConnection? _hub;
  bool _closed = false;
  Completer<CloudPositionFailure?>? _done;
  Timer? _initial;
  Future<void>? _stopping;

  Future<void> _stopHub(HubConnection hub) => _stopping ??= () async {
    try {
      await hub.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Closing the transport releases this connection's consumer lease.
    }
  }();

  Future<CloudPositionFailure?> run({
    required RoleSession role,
    required void Function(PositionSnapshot, String?, String?, DateTime)
    onPosition,
    required void Function(bool) onConnection,
    void Function(PositionSnapshot, String?, String?)? onCachedPosition,
    void Function(String)? onUpstreamError,
  }) async {
    final token = await api.sessionToken();
    if (token == null) {
      return const CloudPositionFailure('Zipliner 登录已失效，请重新登录。');
    }
    if (_closed) return null;
    final done = _done = Completer<CloudPositionFailure?>();
    final headers = MessageHeaders()
      ..setHeaderValue('X-Zipliner-Session', token);
    final hub = _hub = HubConnectionBuilder()
        .withUrl(
          '${api.baseUrl}/hubs/data',
          options: HttpConnectionOptions(
            headers: headers,
            logMessageContent: false,
          ),
        )
        .build();
    String? stream;
    final retiredStreams = <String>{};
    int lastSequence = -1;
    var receivedPosition = false;
    var loggedFirstPosition = false;
    String? upstreamMessage;
    void rememberError(Map data) {
      final source = data['errorSource'];
      final detail = data['message'];
      if ((source != 'skland' && source != 'skport') ||
          detail is! String ||
          detail.trim().isEmpty) {
        return;
      }
      final label = source == 'skport' ? 'SKPort' : '森空岛';
      final code = data['errorCode'];
      final text = '$label${code == null ? "" : "（$code）"}：${detail.trim()}';
      if (upstreamMessage != text) AppLog.instance.warn('共享定位上游错误：$text');
      upstreamMessage = text;
    }

    void finish(CloudPositionFailure? reason) {
      _initial?.cancel();
      if (!done.isCompleted) done.complete(_closed ? null : reason);
    }

    void waitForRecovery(Map data) {
      if (_closed || done.isCompleted) return;
      rememberError(data);
      onConnection(false);
      if (upstreamMessage != null) onUpstreamError?.call(upstreamMessage!);
      _initial ??= Timer(
        const Duration(seconds: 30),
        () =>
            finish(CloudPositionFailure(upstreamMessage ?? '共享定位暂未恢复，正在等待重连。')),
      );
    }

    void receive(List<Object?>? args) {
      if (_closed ||
          done.isCompleted ||
          args == null ||
          args.isEmpty ||
          args.first is! Map) {
        return;
      }
      final data = (args.first as Map).cast<String, dynamic>();
      if (data['roleId']?.toString() != role.binding.roleId ||
          data['serverId']?.toString() != role.binding.serverId) {
        return;
      }
      final snapshot = data['isSnapshot'] == true;
      if (snapshot && receivedPosition) return;
      final nextStream = data['streamId']?.toString();
      final sequence = (data['sequence'] as num?)?.toInt();
      if (nextStream != null && retiredStreams.contains(nextStream)) return;
      if (nextStream != null && nextStream != stream) {
        if (stream != null) retiredStreams.add(stream!);
        stream = nextStream;
        lastSequence = -1;
      }
      if (sequence != null && sequence <= lastSequence) return;
      final now = DateTime.now();
      final observed = DateTime.tryParse(data['observedAt']?.toString() ?? '')
          ?.subtract(api.serverClockOffset);
      final values = [data['x'], data['y'], data['z']];
      if (values.any((v) => v is! num || !v.toDouble().isFinite)) return;
      if (snapshot) {
        onCachedPosition?.call(
          PositionSnapshot(
            (values[0] as num).toDouble(),
            (values[1] as num).toDouble(),
            (values[2] as num).toDouble(),
          ),
          data['mapId']?.toString(),
          data['levelId']?.toString(),
        );
        return;
      }
      if (sequence != null) lastSequence = sequence;
      _initial?.cancel();
      _initial = null;
      receivedPosition = true;
      upstreamMessage = null;
      if (!loggedFirstPosition) {
        loggedFirstPosition = true;
        AppLog.instance.info(
          '共享定位已收到实时坐标；stream=${nextStream ?? "legacy"}；sequence=$sequence',
        );
      }
      onConnection(true);
      onPosition(
        PositionSnapshot(
          (values[0] as num).toDouble(),
          (values[1] as num).toDouble(),
          (values[2] as num).toDouble(),
        ),
        data['mapId']?.toString(),
        data['levelId']?.toString(),
        observed != null && !observed.isAfter(now) ? observed : now,
      );
    }

    hub.on('PositionUpdate', receive);
    hub.on('Online', receive);
    hub.on('Offline', (args) {
      if (args?.firstOrNull is! Map) return;
      final data = args!.first as Map;
      if (data['roleId']?.toString() == role.binding.roleId &&
          data['serverId']?.toString() == role.binding.serverId) {
        waitForRecovery(data);
        // The shared upstream reconnects on its own. Retain this consumer lease
        // so an initial/transient Offline cannot preempt the following Online.
        AppLog.instance.info('共享定位报告离线，保留订阅等待上游恢复。');
      }
    });
    hub.on('PositionError', (args) {
      if (args?.firstOrNull is! Map) return;
      final data = args!.first as Map;
      if (data['roleId']?.toString() == role.binding.roleId &&
          data['serverId']?.toString() == role.binding.serverId) {
        waitForRecovery(data);
        AppLog.instance.warn('共享定位上游暂时异常，保留订阅等待恢复。');
      }
    });
    hub.onclose(
      ({error}) => finish(
        CloudPositionFailure(
          upstreamMessage ?? 'Zipliner 定位连接中断。',
          allowFallback: upstreamMessage == null,
        ),
      ),
    );
    hub.on('SklandConnectionState', (args) {
      if (_closed || done.isCompleted || args?.firstOrNull is! Map) return;
      final data = args!.first as Map;
      if (data['roleId']?.toString() != role.binding.roleId ||
          data['serverId']?.toString() != role.binding.serverId) {
        return;
      }
      if (['Disconnected', 'Reconnecting'].contains(data['state'])) {
        waitForRecovery(data);
      }
      if (['ReconnectFailed', 'Closed'].contains(data['state'])) {
        rememberError(data);
        finish(CloudPositionFailure(upstreamMessage ?? '共享定位上游连接已结束，正在等待重连。'));
      }
    });
    try {
      await hub.start()?.timeout(const Duration(seconds: 20));
      if (_closed) return null;
      await hub
          .invoke(
            'SendAuth',
            args: [
              {
                'roleId': role.binding.roleId,
                'serverId': role.binding.serverId,
                'gameAccountId': role.gameAccountId,
                'autoStartPosition': true,
              },
            ],
          )
          .timeout(const Duration(seconds: 20));
      if (!receivedPosition) {
        _initial ??= Timer(
          const Duration(seconds: 30),
          () => finish(
            CloudPositionFailure(upstreamMessage ?? '共享定位连接成功，但尚未收到实时坐标。'),
          ),
        );
      }
      return await done.future;
    } catch (e) {
      final message = e.toString();
      final rejected = [
        'SessionInvalid',
        'Unauthorized',
        'Forbidden',
        'SklandTokenExpired',
        'SklandCredentialMissing',
        'GameAuthUnavailable',
        'TokenMissing',
        'TokenExpired',
        '403',
        '401',
      ].any(message.contains);
      return CloudPositionFailure(
        rejected ? '云端登录或游戏账号绑定失效，请在账号管理中重新认证。' : '无法连接 Zipliner 定位服务。',
        allowFallback: !rejected,
      );
    } finally {
      _initial?.cancel();
      await _stopHub(hub);
      if (identical(_hub, hub)) _hub = null;
    }
  }

  Future<void> close() async {
    _closed = true;
    _initial?.cancel();
    if (_done?.isCompleted == false) _done!.complete(null);
    final hub = _hub;
    _hub = null;
    if (hub != null) {
      await _stopHub(hub);
    }
  }
}
