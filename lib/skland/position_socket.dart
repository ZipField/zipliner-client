import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'skland_client.dart';
import 'skland_models.dart';

/// 服务端消息类型，数值与后端 `WsMessageType` 相同。
abstract final class WsMessageType {
  static const auth = 1;
  static const authAck = 2;
  static const heartbeat = 3;
  static const heartbeatAck = 4;
  static const remoteClose = 6;
  static const subscribe = 1011;
  static const position = 1012;
}

class PositionMessage {
  const PositionMessage(this.type, {this.position, this.mapId, this.levelId, this.error});

  final int type;
  final PositionSnapshot? position;
  final String? mapId;
  final String? levelId;
  final String? error;

  /// 与后端 `ParseMessage` 相同：解析失败视为远端关闭。
  static PositionMessage parse(String text) {
    try {
      final root = jsonDecode(text);
      if (root is! Map || root['type'] is! num) return const PositionMessage(0);
      final type = (root['type'] as num).toInt();
      final data = root['data'];
      switch (type) {
        case WsMessageType.authAck:
        case WsMessageType.heartbeatAck:
          return PositionMessage(type);
        case WsMessageType.position:
          if (data is! Map || data['pos'] is! Map) return const PositionMessage(0);
          final pos = data['pos'] as Map;
          return PositionMessage(
            type,
            position: PositionSnapshot(_num(pos['x']), _num(pos['y']), _num(pos['z'])),
            mapId: data['mapId']?.toString(),
            levelId: data['levelId']?.toString(),
          );
        case WsMessageType.remoteClose:
          final code = data is Map && data.containsKey('code') ? jsonEncode(data['code']) : null;
          final message = data is Map ? data['message']?.toString() : null;
          return PositionMessage(
            type,
            error: code != null ? '服务器关闭连接（code=$code）：${message ?? '无消息'}' : (message ?? 'WebSocket 已关闭'),
          );
        default:
          return PositionMessage(type);
      }
    } catch (_) {
      return const PositionMessage(WsMessageType.remoteClose, error: '收到无效的 WebSocket 消息');
    }
  }

  static double _num(Object? value) {
    if (value is num) return value.toDouble();
    throw const FormatException('坐标不是数字');
  }
}

typedef PositionCallback = void Function(PositionSnapshot position, String? mapId, String? levelId);

/// 连接 `wss://ws.skland.com/ws/v1/game/endfield/map` 并推送坐标。
class PositionSocket {
  PositionSocket({this.connector});

  static const path = '/ws/v1/game/endfield/map';
  static const initialPositionTimeout = Duration(seconds: 4);
  static const heartbeatInterval = Duration(seconds: 10);
  static const _msgIdChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  /// 测试可替换的连接工厂。
  final Future<WebSocket> Function(String url, Map<String, String> headers)? connector;

  WebSocket? _socket;
  bool _cancelled = false;
  Duration _requestInterval = Duration.zero;
  Timer? _requestTimer;
  void Function()? _requestPosition;

  static void validateRequestInterval(Duration value) {
    if (value != Duration.zero && (value < const Duration(seconds: 1) || value > const Duration(seconds: 10))) {
      throw ArgumentError.value(value, 'requestInterval', '必须为 0 或 1–10 秒');
    }
  }

  /// 调整实际发出的 1011 刷新请求；不改变心跳或丢弃服务端推送。
  Duration get requestInterval => _requestInterval;
  set requestInterval(Duration value) {
    validateRequestInterval(value);
    if (_requestInterval == value) return;
    _requestInterval = value;
    _rescheduleRequests();
  }

  void _rescheduleRequests() {
    _requestTimer?.cancel();
    _requestTimer = null;
    if (_requestPosition != null && _requestInterval > Duration.zero) {
      _requestTimer = Timer.periodic(_requestInterval, (_) => _requestPosition?.call());
    }
  }

  void _stopRequests() {
    _requestTimer?.cancel();
    _requestTimer = null;
    _requestPosition = null;
  }

  /// 运行直到断开，返回断开原因；调用 [close] 主动断开时返回 null。
  Future<String?> run({
    required String websocketToken,
    required RoleBinding role,
    required SklandRegion region,
    required PositionCallback onPosition,
    void Function()? onSubscribed,
    String? language,
  }) async {
    _stopRequests();
    _cancelled = false;
    final headers = {'sk-language': ?SklandClient.skLanguage(region, language)};
    final url = SklandClient.wsUrl(region) + path;
    final WebSocket socket;
    try {
      socket = await (connector ?? _connect)(url, headers);
    } catch (_) {
      return _cancelled ? null : '无法连接到定位服务';
    }
    if (_cancelled) {
      await socket.close();
      return null;
    }
    _socket = socket..pingInterval = const Duration(seconds: 15);

    final done = Completer<String?>();
    Timer? initialTimer;
    Timer? heartbeat;
    var subscribed = false;

    void finish(String? reason) {
      if (done.isCompleted) return;
      initialTimer?.cancel();
      heartbeat?.cancel();
      _stopRequests();
      done.complete(_cancelled ? null : reason);
      socket.close();
    }

    socket.add(_message(WsMessageType.auth, {'token': websocketToken}));
    final subscription = socket.listen(
      (event) {
        if (event is! String) {
          finish('收到无效的 WebSocket 消息');
          return;
        }
        final message = PositionMessage.parse(event);
        if (message.type == WsMessageType.authAck && !subscribed) {
          subscribed = true;
          socket.add(_message(WsMessageType.subscribe, {'roleId': role.roleId, 'serverId': role.serverId}));
          _requestPosition = () {
            try {
              socket.add(_message(WsMessageType.subscribe, {'roleId': role.roleId, 'serverId': role.serverId}));
            } catch (_) {
              finish('WebSocket 连接已断开');
            }
          };
          _rescheduleRequests();
          initialTimer = Timer(initialPositionTimeout, () => finish('角色不在线（未收到坐标）'));
          onSubscribed?.call();
        } else if (message.type == WsMessageType.position && message.position != null) {
          initialTimer?.cancel();
          onPosition(message.position!, message.mapId, message.levelId);
          heartbeat ??= Timer.periodic(heartbeatInterval, (_) {
            try {
              socket.add(_message(WsMessageType.heartbeat, const {}));
            } catch (_) {
              heartbeat?.cancel();
            }
          });
        } else if (message.type == WsMessageType.remoteClose) {
          finish(message.error ?? 'WebSocket 已关闭');
        }
      },
      onError: (_) => finish('WebSocket 连接已断开'),
      onDone: () => finish('WebSocket 已关闭'),
      cancelOnError: true,
    );

    final reason = await done.future;
    await subscription.cancel();
    _socket = null;
    return reason;
  }

  Future<void> close() async {
    _cancelled = true;
    _stopRequests();
    await _socket?.close();
  }

  static Future<WebSocket> _connect(String url, Map<String, String> headers) =>
      WebSocket.connect(url, headers: headers).timeout(const Duration(seconds: 20));

  static String _message(int type, Map<String, Object?> data) =>
      jsonEncode({'type': type, 'data': data, 'msgId': createMsgId()});

  static String createMsgId() {
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(8, (_) => _msgIdChars.codeUnitAt(random.nextInt(256) % _msgIdChars.length)),
    );
  }
}
