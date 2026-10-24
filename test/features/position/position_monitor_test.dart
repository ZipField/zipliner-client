import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/application/client_accounts.dart';
import 'package:zipliner_client/features/accounts/models/account_models.dart';
import 'package:zipliner_client/features/accounts/storage/local_guest_store.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/integrations/skland/skland_client.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';
import 'package:zipliner_client/shared/http/api_client.dart';

import '../../support/fake_adapter.dart';

import '../../support/position_fakes.dart';

class _PendingHubApi extends ApiClient {
  _PendingHubApi() : super(baseUrl: 'https://api.test', cookieJar: CookieJar());

  final session = Completer<String?>();
  int sessionTokenCalls = 0;

  @override
  Future<String?> sessionToken() {
    sessionTokenCalls++;
    return session.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('monitor receives local coordinates while cloud Hub session lookup is pending and after it fails', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final framework = await TfFramework.initialize(
      designSystems: const [Material3DesignSystem()],
      store: TfMemoryPreferenceStore(),
      settingsBuilder: (_) => [],
    );
    const directToken = StoredToken(
      id: 'game-a',
      token: 'user-token',
      region: SklandRegion.skland,
    );
    final guest = LocalGuestStore();
    await guest.save(const [directToken]);
    final hubApi = _PendingHubApi();
    final accounts =
        ClientAccounts(
            hubApi,
            framework.preferences,
            guest,
            TokenRepository(guest),
          )
          ..mode = ClientAccountMode.cloud
          ..identity = ZiplinerIdentity({'accountId': 'cloud-a'})
          ..gameAccounts = [
            CloudGameAccount({'id': 'game-a', 'provider': 'skland'}),
          ]
          ..gameRoles = [
            CloudGameRole({
              'gameAccountId': 'game-a',
              'roleId': '42',
              'serverId': '1',
              'nickname': 'Player',
            }),
          ];
    await framework.preferences.set(
      const TfPreferenceKey<String>(
        'account.cloud:cloud-a.source',
        defaultValue: '',
      ),
      'direct',
    );

    final socket = FakeSocket();
    final dio = Dio(
      BaseOptions(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = FakeAdapter(sklandResponder);
    final monitor = PositionMonitor(
      client: SklandClient(dio: dio),
      tokens: TokenRepository(MemoryTokenStore(const [directToken])),
      accounts: accounts,
      captureDirectory: () async => '.',
      socketFactory: () => socket,
    );
    final run = monitor.start();
    try {
      await pumpUntil(
        () => socket.token != null && hubApi.sessionTokenCalls > 0,
      );
      expect(socket.token, 'ws-token');
      expect(monitor.isConnected, isTrue);
      expect(hubApi.session.isCompleted, isFalse);

      socket.push(7, 8, 9);
      expect(monitor.position?.x, 7);
      expect(monitor.position?.y, 8);
      expect(monitor.isConnected, isTrue);

      hubApi.session.completeError(StateError('Hub unavailable'));
      await Future<void>.delayed(Duration.zero);
      expect(monitor.isConnected, isTrue);
      expect(monitor.position?.x, 7);
      expect(monitor.position?.y, 8);
      expect(socket.token, 'ws-token');
    } finally {
      await monitor.disconnect();
      await run;
      monitor.dispose();
      accounts.dispose();
    }
  });
  test('没有 token 时提示登录', () async {
    final monitor = monitorWith(FakeAdapter(sklandResponder));
    await monitor.start();
    expect(monitor.status, '未登录');
    expect(monitor.warning, '登录后才能连接坐标同步');
    expect(monitor.hasTokens, isFalse);
  });

  test('连接流程：加载角色 → 取 ws token → 接收坐标与 mapId', () async {
    final socket = FakeSocket();
    final monitor = monitorWith(
      FakeAdapter(sklandResponder),
      tokens: [token],
      socket: socket,
    );
    final run = monitor.start();
    await pumpUntil(() => socket.token != null);

    expect(socket.token, 'ws-token');
    expect(socket.role!.roleId, '42');
    expect(monitor.activeRole!.displayName, '官服 - 管理员');
    expect(monitor.status, '已连接：官服 - 管理员，等待坐标...');

    socket.push(1, 2, 3);
    expect(monitor.status, '坐标已更新');
    expect(monitor.mapId, 'map01');
    socket.push(4, 5, 6, mapId: null);
    expect(monitor.mapId, 'map01', reason: '消息缺少 mapId 时保留上一次的值');
    expect(monitor.position!.x, 4);

    socket.end('WebSocket 已关闭');
    await run;
    expect(monitor.status, 'WebSocket 已关闭');
    expect(monitor.isError, isTrue);
    expect(monitor.problem!.title, '连接中断');
    expect(monitor.nextRetryAt, isNotNull, reason: '连接中断后应自动重连');
    await monitor.disconnect();
    expect(monitor.nextRetryAt, isNull);
  });

  test('未同意位置政策时停下等待用户确认，确认后调用同意接口并连接', () async {
    var agreed = false;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/agree-policy')) agreed = true;
      return sklandResponder(request, agreed: agreed);
    });
    final socket = FakeSocket();
    final monitor = monitorWith(adapter, tokens: [token], socket: socket);

    await monitor.start();
    expect(monitor.policyRequired, isTrue);
    expect(socket.token, isNull);

    unawaited(monitor.agreePolicyAndConnect());
    await pumpUntil(() => socket.token != null);
    expect(agreed, isTrue);
    expect(monitor.policyRequired, isFalse);
    await monitor.disconnect();
  });

  test('采集：拿到 mapId 后获取滑索标记并实时识别', () async {
    final socket = FakeSocket();
    final monitor = monitorWith(
      FakeAdapter(sklandResponder),
      tokens: [token],
      socket: socket,
    );
    final detections = <String>[];
    monitor.collection.onDetection = (stop) => detections.add(stop.label);
    unawaited(monitor.start());
    await pumpUntil(() => socket.token != null);

    await monitor.collection.startCapture();
    expect(monitor.warning, '已开始采集；等待地图、登录和角色信息后再获取滑索数据');

    socket.push(1, 13.5, 1);
    await pumpUntil(() => monitor.collection.detector != null);
    expect(monitor.warning, '已获取滑索数据：1 个，停在滑索上等待识别');

    socket.push(1, 13.5, 1);
    socket.push(1.05, 13.5, 1);
    expect(detections, ['(1,10,1,北)']);
    expect(monitor.warning, '已识别第 1 个滑索：(1,10,1,北)');

    await monitor.collection.manualDetect();
    expect(monitor.collection.lookupResult!.toTupleText(), '(1,10,1,北)');

    monitor.collection.stopCapture();
    expect(monitor.warning, '已停止采集');
    await monitor.disconnect();
  });
}
