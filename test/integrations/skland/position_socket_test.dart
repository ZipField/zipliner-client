import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/integrations/skland/position_socket.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

class _Socket extends Stream<dynamic> implements WebSocket {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Duration? pingInterval;
  int get requests => sent
      .where((message) => message['type'] == WsMessageType.subscribe)
      .length;
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
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'official socket waits the full thirty seconds for coordinates and auth ack does not reset the deadline',
    (tester) async {
      final transport = _Socket();
      final socket = PositionSocket(connector: (_, _) async => transport);
      String? reason;
      final run = socket.run(
        websocketToken: 'test',
        role: const RoleBinding(serverId: '1', roleId: '42'),
        region: SklandRegion.skland,
        onPosition: (_, _, _) {},
      );
      unawaited(run.then((value) => reason = value));
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      transport.receive(WsMessageType.authAck);
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(reason, isNull);
      await tester.pump(const Duration(seconds: 1));
      for (var i = 0; i < 20 && reason == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      expect(reason, contains('30'));
      expect(transport.closed, isTrue);
    },
  );

  testWidgets(
    'unchanged positions every twenty seconds keep the socket alive, then thirty seconds without one closes it',
    (tester) async {
      final transport = _Socket();
      final socket = PositionSocket(connector: (_, _) async => transport);
      var finished = false;
      String? reason;
      final run = socket.run(
        websocketToken: 'test',
        role: const RoleBinding(serverId: '1', roleId: '42'),
        region: SklandRegion.skland,
        onPosition: (_, _, _) {},
      );
      unawaited(
        run.then((value) {
          finished = true;
          reason = value;
        }),
      );
      await tester.pump();
      transport.receive(WsMessageType.authAck);
      transport.receive(WsMessageType.position, {
        'pos': {'x': 1, 'y': 2, 'z': 3},
      });
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 20));
        transport.receive(WsMessageType.position, {
          'pos': {'x': 1, 'y': 2, 'z': 3},
        });
        await tester.pump();
        expect(finished, isFalse);
      }
      await tester.pump(const Duration(seconds: 29));
      expect(finished, isFalse);
      await tester.pump(const Duration(seconds: 1));
      for (var i = 0; i < 20 && !finished; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      expect(reason, contains('30'));
      expect(transport.closed, isTrue);
    },
  );

  testWidgets('仅首次订阅，后续保留推送与心跳，不定时请求坐标', (tester) async {
    final transport = _Socket();
    final socket = PositionSocket(connector: (_, _) async => transport);
    var positions = 0;
    final run = socket.run(
      websocketToken: 'test',
      role: const RoleBinding(serverId: '1', roleId: '42'),
      region: SklandRegion.skland,
      onPosition: (_, _, _) => positions++,
    );
    var finished = false;
    String? finishReason;
    unawaited(
      run.then((reason) {
        finished = true;
        finishReason = reason;
      }),
    );
    await tester.pump();
    expect(transport.requests, 0);
    transport.receive(WsMessageType.authAck);
    transport.receive(WsMessageType.position, {
      'pos': {'x': 1, 'y': 2, 'z': 3},
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(transport.requests, 1);
    expect(
      transport.sent.where((m) => m['type'] == WsMessageType.heartbeat),
      isNotEmpty,
    );
    transport.receive(WsMessageType.position, {
      'pos': {'x': 2, 'y': 3, 'z': 4},
    });
    await tester.pump();
    expect(positions, 2);
    // Advance the widget test's fake clock before waiting for close completion.
    // Awaiting it first can leave its timeout and stream cleanup unable to run.
    var closed = false;
    unawaited(socket.close().then((_) => closed = true));
    await tester.pump();
    // Stream cancellation can use a completed Future from outside FakeAsync.
    // Let that event-loop turn finish before flushing fake-zone continuations.
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    // Stream cancellation may finish after a later event-loop turn. Keep
    // advancing fake time, with a bound above the one-second close timeout.
    for (var i = 0; i < 20 && (!closed || !finished); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(closed, isTrue);
    expect(transport.closed, isTrue);
    expect(finished, isTrue);
    expect(finishReason, isNull);
    await tester.pump(const Duration(seconds: 20));
    expect(transport.requests, 1);
  });
}
