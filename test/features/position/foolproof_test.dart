import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/features/settings/application/update_checker.dart';
import 'package:zipliner_client/features/position/models/friendly_error.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/integrations/skland/position_socket.dart';
import 'package:zipliner_client/integrations/skland/skland_client.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

import '../../support/position_fakes.dart'
    show FakeSocket, pumpUntil, sklandResponder, token;
import '../../support/fake_adapter.dart';

void main() {
  group('FriendlyError', () {
    test('登录失效类错误提示重新登录，且不自动重试', () {
      for (final raw in ['token 无效或已过期（请求失败: 400）', '请求失败: 401']) {
        final e = FriendlyError.explain(raw);
        expect(e.title, '登录已失效', reason: raw);
        expect(e.action, FixAction.relogin);
        expect(e.retryable, isFalse);
      }
    });

    test('upstream role and data errors retain their message and retry after 30 seconds', () {
      for (final raw in [
        '服务器关闭连接（code=19001）：无法获取当前角色位置，请确保已登录游戏',
        '服务器关闭连接（code="19005"）：数据异常，稍后再试',
        '森空岛（19001）：无法获取当前角色位置，请确保已登录游戏',
      ]) {
        final error = FriendlyError.explain(raw);
        expect(error.title, isNot(contains('1900')), reason: raw);
        expect(error.title, isNot(contains('森空岛')), reason: raw);
        expect(
          error.title,
          contains(raw.contains('19001') ? '无法获取当前角色位置' : '数据异常'),
          reason: raw,
        );
        expect(error.action, FixAction.reconnect);
        expect(error.retryable, isTrue);
        expect(error.retryDelay, const Duration(seconds: 30));
      }
    });

    test('socket auth errors are not account-login failures and kick errors never auto-retry', () {
      for (final raw in [
        '服务器关闭连接（code=10002）：鉴权信息无效',
        '服务器关闭连接（code="10002"）：鉴权信息无效',
        '服务器关闭连接：鉴权信息无效',
      ]) {
        final error = FriendlyError.explain(raw);
        expect(error.title, '鉴权信息无效', reason: raw);
        expect(error.action, FixAction.reconnect);
        expect(error.retryable, isFalse);
        expect(error.title, isNot('登录已失效'));
      }

      final kick = FriendlyError.explain('服务器关闭连接（code=10003）：定位连接已被其他会话接管');
      expect(kick.title, '定位连接已被其他会话接管');
      expect(kick.action, FixAction.reconnect);
      expect(kick.retryable, isFalse);
    });

    test('角色不在线、网络、连接中断会自动重试', () {
      final offline = FriendlyError.explain('角色不在线（未收到坐标）');
      expect(offline.retryable, isTrue);
      expect(offline.retryDelay, const Duration(seconds: 15));
      expect(FriendlyError.explain('无法连接到森空岛，请检查网络').retryable, isTrue);
      expect(FriendlyError.explain('WebSocket 已关闭').title, '连接中断');
    });

    test('政策与无角色给出对应操作，未知错误保留原文', () {
      expect(
        FriendlyError.explain('需要同意森空岛位置同步政策').action,
        FixAction.agreePolicy,
      );
      expect(FriendlyError.explain('未找到终末地角色').title, '这个账号下没有终末地角色');
      final unknown = FriendlyError.explain('奇怪的错误');
      expect(unknown.title, '奇怪的错误');
      expect(unknown.retryable, isFalse);
    });
  });

  group('UpdateChecker.isNewer', () {
    test('按语义化版本比较', () {
      expect(UpdateChecker.isNewer('v0.2.0', 'v0.1.9'), isTrue);
      expect(UpdateChecker.isNewer('v1.0.0', 'v1.0.0'), isFalse);
      expect(UpdateChecker.isNewer('v0.1.10', 'v0.1.9'), isTrue);
      expect(UpdateChecker.isNewer('0.3.0', 'v0.2.5'), isTrue);
      expect(UpdateChecker.isNewer('v0.1.0', 'v0.2.0'), isFalse);
    });

    test('开发版（dev）不提示更新', () {
      expect(UpdateChecker.isNewer('v9.9.9', 'dev'), isFalse);
    });
  });

  group('TokenRepository', () {
    test('重新登录替换凭据并保留位置，显示名可更新', () async {
      final repo = TokenRepository(
        MemoryTokenStore(const [
          StoredToken(id: 'a', token: 'old', region: SklandRegion.skland),
          StoredToken(id: 'b', token: 'other', region: SklandRegion.skland),
        ]),
      );
      await repo.setLabel('a', '管理员');
      await repo.replace('a', 'new', SklandRegion.skport);
      final list = await repo.list();
      expect(list.map((t) => t.id), ['a', 'b']);
      expect(list.first.token, 'new');
      expect(list.first.region, SklandRegion.skport);
      expect(list.first.label, '管理员');
    });

    test('替换成已存在的 token 时去掉重复项', () async {
      final repo = TokenRepository(
        MemoryTokenStore(const [
          StoredToken(id: 'a', token: 'old', region: SklandRegion.skland),
          StoredToken(id: 'b', token: 'dup', region: SklandRegion.skland),
        ]),
      );
      await repo.replace('a', 'dup', SklandRegion.skland);
      expect((await repo.list()).map((t) => t.id), ['a']);
    });
  });

  test('连接中断后按退避间隔自动重连，收到坐标后恢复', () async {
    final sockets = <FakeSocket>[];
    final dio = Dio(
      BaseOptions(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = FakeAdapter(sklandResponder);
    final monitor = PositionMonitor(
      client: SklandClient(dio: dio),
      tokens: TokenRepository(MemoryTokenStore(const [token])),
      captureDirectory: () async => '.',
      socketFactory: () {
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      retryDelays: const [Duration(milliseconds: 20)],
    );
    addTearDown(monitor.disconnect);

    final run = monitor.start();
    await pumpUntil(() => sockets.isNotEmpty && sockets.first.token != null);
    sockets.first.end('WebSocket 连接已断开');
    await run;
    expect(monitor.retryInSeconds, isNotNull);

    await pumpUntil(() => sockets.length == 2 && sockets.last.token != null);
    expect(sockets, hasLength(2), reason: '应自动发起第二次连接');
    sockets.last.push(1, 2, 3);
    expect(monitor.problem, isNull);
    expect(monitor.status, '坐标已更新');
  });

  test(
    'each 10002 rejection refreshes the token and remains retryable',
    () async {
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
      final dio = Dio(
        BaseOptions(
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      )..httpClientAdapter = adapter;
      final sockets = <FakeSocket>[];
      final monitor = PositionMonitor(
        client: SklandClient(dio: dio),
        tokens: TokenRepository(MemoryTokenStore(const [token])),
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
      sockets.first.end('服务器关闭连接（code=10002）：鉴权信息无效');
      await firstRun;
      await pumpUntil(() => sockets.length == 2 && sockets.last.token != null);
      expect(sockets.last.token, 'ws-token-2');

      sockets.last.push(1, 2, 3);
      expect(monitor.problem, isNull);
      expect(monitor.position, isNotNull);
      sockets.last.end('服务器关闭连接（code="10002"）：鉴权信息无效');
      await pumpUntil(() => sockets.length == 3 && sockets.last.token != null);
      expect(sockets.last.token, 'ws-token-3');

      sockets.last.end('服务器关闭连接（code=10002）：鉴权信息无效');
      await pumpUntil(() => sockets.length == 4 && sockets.last.token != null);
      expect(sockets.last.token, 'ws-token-4');
      sockets.last.push(4, 5, 6);
      expect(monitor.position?.x, 4);
      expect(monitor.problem, isNull);
      expect(
        adapter.requests.where((r) => r.uri.path.endsWith('/grant')),
        hasLength(1),
      );
      expect(
        adapter.requests.where((r) => r.uri.path.endsWith('/websocket/token')),
        hasLength(4),
      );

      await monitor.disconnect();
      monitor.dispose();
    },
  );

  test('登录失效不自动重连，并记录失败的账号', () async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/grant')) {
        return FakeResponse.text('{"msg":"bad"}', status: 400);
      }
      return sklandResponder(request);
    });
    final dio = Dio(
      BaseOptions(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = adapter;
    final monitor = PositionMonitor(
      client: SklandClient(dio: dio),
      tokens: TokenRepository(MemoryTokenStore(const [token])),
      captureDirectory: () async => '.',
      socketFactory: PositionSocket.new,
    );
    await monitor.start();
    expect(monitor.problem!.action, FixAction.relogin);
    expect(monitor.nextRetryAt, isNull);
    expect(monitor.failedAccounts.keys, ['t1']);
  });
}
