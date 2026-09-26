import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/core/api_client.dart';
import 'package:zipliner_client/core/api_exception.dart';

import 'support/fake_adapter.dart';

const _base = 'https://api.test';

Map<String, Object?> _ok(Object? data) => {'success': true, 'data': data, 'message': null};

void main() {
  late CookieJar jar;

  setUp(() => jar = CookieJar());

  ApiClient client(FakeAdapter adapter) =>
      ApiClient(baseUrl: '$_base/', cookieJar: jar, origin: 'https://zipliner.org', httpClientAdapter: adapter);

  Future<void> signIn() => jar.saveFromResponse(Uri.parse(_base), [Cookie('zipliner_session', 'sess-1')]);

  test('解开 success 信封并返回 data', () async {
    final adapter = FakeAdapter((_) => FakeResponse.json(_ok({'status': 'Healthy'})));
    final api = client(adapter);

    expect(await api.get('/health'), {'status': 'Healthy'});
    expect(adapter.requests.single.uri.toString(), '$_base/health');
  });

  test('success:false 即使是 2xx 也抛出 ApiException，并保留 code', () async {
    final adapter = FakeAdapter(
      (_) => FakeResponse.json({'success': false, 'data': null, 'message': '账号已变更', 'code': 'ACCOUNT_CHANGED'}),
    );
    final api = client(adapter);

    await expectLater(
      api.get('/api/web/settings'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'ACCOUNT_CHANGED')
            .having((e) => e.message, 'message', '账号已变更'),
      ),
    );
  });

  test('纯文本错误体（中间件返回）作为错误消息', () async {
    final adapter = FakeAdapter((_) => FakeResponse.text('Origin not allowed', status: 403));
    final api = client(adapter);

    await expectLater(
      api.post('/api/feedback', body: {}),
      throwsA(
        isA<ApiException>()
            .having((e) => e.message, 'message', 'Origin not allowed')
            .having((e) => e.statusCode, 'status', 403),
      ),
    );
  });

  test('POST 带 Origin，GET 不带；空查询参数被丢弃', () async {
    final adapter = FakeAdapter((_) => FakeResponse.json(_ok(null)));
    final api = client(adapter);

    await api.get('/api/wiki/pages', query: {'q': '', 'page': 1, 'tag': null});
    await api.post('/api/system/ping');

    expect(adapter.requests[0].headers.containsKey('Origin'), isFalse);
    expect(adapter.requests[0].uri.query, 'page=1');
    expect(adapter.requests[1].headers['Origin'], 'https://zipliner.org');
  });

  test('有会话时，受保护的 /api/account POST 先取 CSRF 并复用', () async {
    await signIn();
    final adapter = FakeAdapter((request) {
      if (request.path == '/api/account/csrf') {
        return FakeResponse.json(_ok({'csrfToken': 'csrf-1', 'expiresInSeconds': 1800}));
      }
      return FakeResponse.json(_ok({'updated': true}));
    });
    final api = client(adapter);

    await api.post('/api/account/game-accounts/set-default', body: {'gameAccountId': 'g1'}, auth: true);
    await api.post('/api/account/logout', auth: true);

    expect(adapter.requests.map((r) => r.path), [
      '/api/account/csrf',
      '/api/account/game-accounts/set-default',
      '/api/account/logout',
    ]);
    expect(adapter.requests[1].headers[ApiClient.csrfHeader], 'csrf-1');
    expect(adapter.requests[2].headers[ApiClient.csrfHeader], 'csrf-1');
    expect(adapter.requests[1].headers['cookie'], contains('zipliner_session=sess-1'));
  });

  test('豁免路由（登录）和非 account 路由不取 CSRF', () async {
    await signIn();
    final adapter = FakeAdapter((_) => FakeResponse.json(_ok(null)));
    final api = client(adapter);

    await api.post('/api/account/login/password', body: {'email': 'a@b.c', 'password': 'x'});
    await api.post('/api/feedback', body: {}, auth: true);

    expect(adapter.requests.map((r) => r.path), ['/api/account/login/password', '/api/feedback']);
    expect(adapter.requests.every((r) => !r.headers.containsKey(ApiClient.csrfHeader)), isTrue);
  });

  test('CSRF 失效时刷新令牌并重试一次', () async {
    await signIn();
    var csrfCalls = 0;
    var postCalls = 0;
    final adapter = FakeAdapter((request) {
      if (request.path == '/api/account/csrf') {
        csrfCalls++;
        return FakeResponse.json(_ok({'csrfToken': 'csrf-$csrfCalls', 'expiresInSeconds': 1800}));
      }
      postCalls++;
      return postCalls == 1
          ? FakeResponse.text('CSRF token invalid', status: 403)
          : FakeResponse.json(_ok({'ok': true}));
    });
    final api = client(adapter);

    expect(await api.post('/api/account/logout', auth: true), {'ok': true});
    expect(csrfCalls, 2);
    expect(adapter.requests.last.headers[ApiClient.csrfHeader], 'csrf-2');
  });

  test('需要登录的请求 401 时通知 onUnauthorized；登录失败的 401 不通知', () async {
    final adapter = FakeAdapter(
      (_) => FakeResponse.json({'success': false, 'data': null, 'message': '未登录'}, status: 401),
    );
    final api = client(adapter);
    final notified = <ApiException>[];
    api.onUnauthorized = notified.add;

    await expectLater(api.get('/api/account/session', auth: true), throwsA(isA<ApiException>()));
    await expectLater(api.post('/api/account/login/password', body: {}), throwsA(isA<ApiException>()));

    expect(notified, hasLength(1));
    expect(notified.single.isUnauthorized, isTrue);
  });

  test('sessionToken 从 Cookie jar 读取，clearSession 后清空', () async {
    final api = client(FakeAdapter((_) => FakeResponse.json(_ok(null))));
    expect(await api.sessionToken(), isNull);

    await signIn();
    expect(await api.sessionToken(), 'sess-1');

    await api.clearSession();
    expect(await api.hasSession(), isFalse);
  });
}
