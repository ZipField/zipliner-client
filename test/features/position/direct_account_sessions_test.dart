import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/features/position/application/direct_account_sessions.dart';
import 'package:zipliner_client/integrations/skland/skland_client.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

import '../../support/fake_adapter.dart';
import '../../support/position_fakes.dart' show sklandResponder;

void main() {
  test(
    'login, role loading, policy and socket token are reused until rejected',
    () async {
      var socketTokenRequests = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/websocket/token')) {
          socketTokenRequests++;
          return FakeResponse.json({
            'code': 0,
            'data': {'token': 'ws-token-$socketTokenRequests'},
          });
        }
        return sklandResponder(request);
      });
      final dio = Dio(
        BaseOptions(
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      )..httpClientAdapter = adapter;
      final sessions = DirectAccountSessions(SklandClient(dio: dio), null);
      const first = StoredToken(
        id: 'same-id',
        token: 'credential-v1',
        region: SklandRegion.skland,
      );

      final role = (await sessions.local(first)).single;
      expect(await sessions.policyAgreed(role), isTrue);
      expect(await sessions.socketToken(role), 'ws-token-1');

      final reloadedRole = (await sessions.local(first)).single;
      expect(await sessions.policyAgreed(reloadedRole), isTrue);
      expect(await sessions.socketToken(reloadedRole), 'ws-token-1');
      sessions.forgetSocketToken(reloadedRole);
      expect(await sessions.socketToken(reloadedRole), 'ws-token-2');
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/grant'),
        ),
        hasLength(1),
      );
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/player/binding'),
        ),
        hasLength(1),
      );
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/map/me'),
        ),
        hasLength(1),
      );
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/websocket/token'),
        ),
        hasLength(2),
      );

      const rotated = StoredToken(
        id: 'same-id',
        token: 'credential-v2',
        region: SklandRegion.skland,
      );
      final rotatedRole = (await sessions.local(rotated)).single;
      await sessions.policyAgreed(rotatedRole);
      expect(await sessions.socketToken(rotatedRole), 'ws-token-3');
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/grant'),
        ),
        hasLength(2),
      );
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/player/binding'),
        ),
        hasLength(2),
      );
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/map/me'),
        ),
        hasLength(2),
      );
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/websocket/token'),
        ),
        hasLength(3),
      );
    },
  );

  test('a failed socket token request can be retried', () async {
    var socketTokenRequests = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/websocket/token')) {
        socketTokenRequests++;
        if (socketTokenRequests == 1) {
          return FakeResponse.json({'code': 1, 'message': 'temporary error'});
        }
        return FakeResponse.json({
          'code': 0,
          'data': {'token': 'recovered-token'},
        });
      }
      return sklandResponder(request);
    });
    final dio = Dio(
      BaseOptions(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = adapter;
    final sessions = DirectAccountSessions(SklandClient(dio: dio), null);
    const stored = StoredToken(
      id: 'retry-id',
      token: 'credential',
      region: SklandRegion.skland,
    );
    final role = (await sessions.local(stored)).single;

    await expectLater(sessions.socketToken(role), throwsA(isA<Exception>()));
    expect(await sessions.socketToken(role), 'recovered-token');
    expect(socketTokenRequests, 2);
  });
}
