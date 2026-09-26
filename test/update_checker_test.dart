import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/core/update_checker.dart';

import 'support/fake_adapter.dart';

void main() {
  test('检查最新 Release 并合并同时发起的检查', () async {
    final adapter = FakeAdapter(
      (_) => FakeResponse.json({
        'tag_name': 'v0.2.0',
        'html_url': 'https://github.com/ZipField/zipliner-client/releases/tag/v0.2.0',
        'draft': false,
        'prerelease': false,
      }),
    );
    final checker = UpdateChecker(dio: Dio()..httpClientAdapter = adapter, currentVersion: 'v0.1.3');
    final results = await Future.wait([checker.check(), checker.check()]);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.uri.path, '/repos/ZipField/zipliner-client/releases/latest');
    expect(results[0]?.version, 'v0.2.0');
    expect(identical(results[0], results[1]), isTrue);
    expect(checker.checking, isFalse);
    checker.dispose();
  });

  test('忽略预发布、草稿及无效版本，网络失败不抛出', () async {
    for (final data in [
      {'tag_name': 'v99.0.0', 'prerelease': true},
      {'tag_name': 'v99.0.0', 'draft': true},
      {'tag_name': 'v99.0.0-beta'},
      {'tag_name': 'v0.1.3'},
    ]) {
      final checker = UpdateChecker(
        dio: Dio()..httpClientAdapter = FakeAdapter((_) => FakeResponse.json(data)),
        currentVersion: 'v0.1.3',
      );
      expect(await checker.check(), isNull);
      expect(checker.available, isNull);
      checker.dispose();
    }
    final checker = UpdateChecker(
      dio: Dio()..httpClientAdapter = FakeAdapter((_) => throw StateError('offline')),
      currentVersion: 'v0.1.3',
    );
    expect(await checker.check(), isNull);
    expect(checker.lastResult, contains('检查更新失败'));
    checker.dispose();
  });

  testWidgets('启动检查、六小时复查、重复启动和释放', (tester) async {
    final adapter = FakeAdapter((_) => FakeResponse.json({'tag_name': 'v0.2.0'}));
    final checker = UpdateChecker(dio: Dio()..httpClientAdapter = adapter, currentVersion: 'v0.1.3');
    checker.startAutomaticChecks();
    checker.startAutomaticChecks();
    await tester.pump(const Duration(seconds: 2));
    expect(adapter.requests, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(adapter.requests, hasLength(1));
    expect(checker.available?.version, 'v0.2.0');
    await tester.pump(const Duration(hours: 6));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(adapter.requests, hasLength(2));
    checker.dispose();
    await tester.pump(const Duration(hours: 6));
    expect(adapter.requests, hasLength(2));
  });
}
