import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/core/update_checker.dart';
import 'package:zipliner_client/position/friendly_error.dart';
import 'package:zipliner_client/position/position_monitor.dart';
import 'package:zipliner_client/position/token_store.dart';
import 'package:zipliner_client/skland/position_socket.dart';
import 'package:zipliner_client/skland/skland_client.dart';
import 'package:zipliner_client/skland/skland_models.dart';

import 'position_monitor_test.dart' show FakeSocket, pumpUntil, sklandResponder, token;
import 'support/fake_adapter.dart';

void main() {
  group('FriendlyError', () {
    test('登录失效类错误提示重新登录，且不自动重试', () {
      for (final raw in ['token 无效或已过期（请求失败: 400）', '服务器关闭连接（code=10002）：鉴权信息无效', '请求失败: 401']) {
        final e = FriendlyError.explain(raw);
        expect(e.title, '登录已失效', reason: raw);
        expect(e.action, FixAction.relogin);
        expect(e.retryable, isFalse);
      }
    });

    test('角色不在线、网络、连接中断会自动重试', () {
      final offline = FriendlyError.explain('角色不在线（未收到坐标）');
      expect(offline.retryable, isTrue);
      expect(offline.retryDelay, const Duration(seconds: 15));
      expect(FriendlyError.explain('无法连接到森空岛，请检查网络').retryable, isTrue);
      expect(FriendlyError.explain('WebSocket 已关闭').title, '连接中断');
    });

    test('政策与无角色给出对应操作，未知错误保留原文', () {
      expect(FriendlyError.explain('需要同意森空岛位置同步政策').action, FixAction.agreePolicy);
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
    final dio = Dio(BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true))
      ..httpClientAdapter = FakeAdapter(sklandResponder);
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

  test('登录失效不自动重连，并记录失败的账号', () async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/grant')) return FakeResponse.text('{"msg":"bad"}', status: 400);
      return sklandResponder(request);
    });
    final dio = Dio(BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
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
