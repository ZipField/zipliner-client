import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/core/services.dart';
import 'package:zipliner_client/position/position_prefs.dart';
import 'package:zipliner_client/skland/position_socket.dart';
import 'package:zipliner_client/skland/skland_models.dart';

class _Socket extends Stream<dynamic> implements WebSocket {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Duration? pingInterval;
  int get requests => sent.where((message) => message['type'] == WsMessageType.subscribe).length;
  void receive(int type, [Map<String, Object?> data = const {}]) =>
      incoming.add(jsonEncode({'type': type, 'data': data}));
  @override
  void add(dynamic data) {
    if (closed) throw StateError('closed');
    sent.add(jsonDecode(data as String) as Map<String, dynamic>);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (closed) return;
    closed = true;
    unawaited(incoming.close());
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const role = RoleBinding(serverId: '1', roleId: '42');
  testWidgets('真实出站请求按间隔发送，切换立即重排，自动模式取消刷新且保留推送与心跳', (tester) async {
    final transport = _Socket();
    final socket = PositionSocket(connector: (_, _) async => transport);
    var positions = 0;
    socket.requestInterval = const Duration(seconds: 1);
    final run = socket.run(
      websocketToken: 'test',
      role: role,
      region: SklandRegion.skland,
      onPosition: (_, _, _) => positions++,
    );
    bool completed = false;
    String? reason;
    unawaited(
      run.then((value) {
        completed = true;
        reason = value;
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(transport.requests, 0, reason: '鉴权前不请求');
    transport.receive(WsMessageType.authAck);
    await tester.pump();
    expect(transport.requests, 1);
    transport.receive(WsMessageType.position, {
      'pos': {'x': 1, 'y': 2, 'z': 3},
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(transport.requests, 4);
    expect(transport.sent.last['data'], {'roleId': '42', 'serverId': '1'});
    socket.requestInterval = const Duration(seconds: 5);
    await tester.pump(const Duration(seconds: 4));
    expect(transport.requests, 4, reason: '旧计时器已取消');
    await tester.pump(const Duration(seconds: 1));
    expect(transport.requests, 5);
    socket.requestInterval = Duration.zero;
    await tester.pump(const Duration(seconds: 10));
    expect(transport.requests, 5);
    expect(transport.sent.where((m) => m['type'] == WsMessageType.heartbeat), isNotEmpty);
    transport.receive(WsMessageType.position, {
      'pos': {'x': 2, 'y': 3, 'z': 4},
    });
    await tester.pump();
    expect(positions, 2);
    socket.requestInterval = const Duration(seconds: 1);
    await tester.pump(const Duration(seconds: 1));
    expect(transport.requests, 6);
    await socket.close();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(completed, isTrue);
    expect(reason, isNull);
    await tester.pump(const Duration(seconds: 20));
    expect(transport.requests, 6);
  });

  testWidgets('服务器关闭后停止刷新，再次连接沿用速度且只建立一组计时器', (tester) async {
    var transport = _Socket();
    final socket = PositionSocket(connector: (_, _) async => transport)..requestInterval = const Duration(seconds: 3);
    Future<String?> start() =>
        socket.run(websocketToken: 'test', role: role, region: SklandRegion.skland, onPosition: (_, _, _) {});
    var run = start();
    String? reason;
    unawaited(run.then((value) => reason = value));
    await tester.pump();
    transport.receive(WsMessageType.authAck);
    transport.receive(WsMessageType.position, {
      'pos': {'x': 1, 'y': 2, 'z': 3},
    });
    await tester.pump();
    transport.receive(WsMessageType.remoteClose, {'message': '断开'});
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(reason, '断开');
    await tester.pump(const Duration(seconds: 10));
    expect(transport.requests, 1);
    transport = _Socket();
    run = start();
    bool completed = false;
    unawaited(run.then((_) => completed = true));
    await tester.pump();
    transport.receive(WsMessageType.authAck);
    transport.receive(WsMessageType.position, {
      'pos': {'x': 1, 'y': 2, 'z': 3},
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(transport.requests, 3);
    await socket.close();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(completed, isTrue);
  });

  test('设置通过服务装配生效并在释放服务后取消监听', () async {
    final prefs = TfPreferencesController(store: TfMemoryPreferenceStore());
    await prefs.load();
    final services = AppServices.inMemory(prefs);
    expect(services.monitor.requestInterval, Duration.zero);
    await prefs.set(PositionPrefs.requestSeconds, 5);
    expect(services.monitor.requestInterval, const Duration(seconds: 5));
    services.dispose();
    await prefs.set(PositionPrefs.requestSeconds, 1);
    expect(services.monitor.requestInterval, const Duration(seconds: 5));
    expect(() => PositionSocket().requestInterval = const Duration(milliseconds: 10), throwsArgumentError);
  });
}
