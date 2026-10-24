import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/features/position/models/position_connection.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/integrations/skland/skland_client.dart';

import '../../support/position_fakes.dart'
    show FakeSocket, monitorWith, pumpUntil, sklandResponder, token;
import '../../support/fake_adapter.dart';

void main() {
  test(
    'a late coordinate from a stopped socket cannot restore connection state',
    () async {
      final socket = FakeSocket();
      final monitor = monitorWith(
        FakeAdapter(sklandResponder),
        tokens: [token],
        socket: socket,
      );
      addTearDown(monitor.dispose);
      final run = monitor.start();
      await pumpUntil(() => socket.token != null);
      socket.push(1, 2, 3);
      await monitor.disconnect();
      await run;
      final revision = monitor.positionRevision;
      socket.push(9, 9, 9);
      expect(monitor.phase, PositionPhase.stopped);
      expect(monitor.position, isNull);
      expect(monitor.positionRevision, revision);
    },
  );

  test('offline and 19001 reconnects reuse the WebSocket token without repeating account login', () async {
    var issuedTokens = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/websocket/token')) {
        issuedTokens++;
        return FakeResponse.json({
          'code': 0,
          'data': {'token': 'ws-token-$issuedTokens'},
        });
      }
      return sklandResponder(request);
    });
    final sockets = <FakeSocket>[];
    final dio = Dio(
      BaseOptions(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = adapter;
    final monitor = PositionMonitor(
      client: SklandClient(dio: dio),
      tokens: TokenRepository(MemoryTokenStore([token])),
      captureDirectory: () async => '.',
      socketFactory: () {
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      retryDelays: const [Duration(milliseconds: 30)],
    );
    final firstRun = monitor.start();
    await pumpUntil(() => sockets.length == 1 && sockets.first.token != null);
    sockets.first.end('WebSocket 已关闭');
    await firstRun;

    await pumpUntil(() => sockets.length == 2 && sockets.last.token != null);
    expect(sockets.map((socket) => socket.token), ['ws-token-1', 'ws-token-1']);
    expect(
      adapter.requests.where((r) => r.uri.path.endsWith('/grant')),
      hasLength(1),
    );
    expect(
      adapter.requests.where((r) => r.uri.path.endsWith('/player/binding')),
      hasLength(1),
    );
    expect(
      adapter.requests.where((r) => r.uri.path.endsWith('/map/me')),
      hasLength(1),
    );
    sockets.last.end('服务器关闭连接（code=19001）：无法获取当前角色位置，请确保已登录游戏');
    await pumpUntil(() => monitor.problem?.retryable == true);
    final thirdRun = monitor.start();
    await pumpUntil(() => sockets.length == 3 && sockets.last.token != null);
    expect(sockets.map((socket) => socket.token), [
      'ws-token-1',
      'ws-token-1',
      'ws-token-1',
    ]);
    expect(
      adapter.requests.where((r) => r.uri.path.endsWith('/websocket/token')),
      hasLength(1),
    );

    await monitor.disconnect();
    await thirdRun;
    monitor.dispose();
  });
}
