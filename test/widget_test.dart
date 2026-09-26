import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/app.dart';
import 'package:zipliner_client/core/services.dart';
import 'package:zipliner_client/core/update_checker.dart';
import 'package:zipliner_client/desktop/desktop_overlay.dart';
import 'package:dio/dio.dart';

import 'position_monitor_test.dart' show FakeSocket, sklandResponder, token;
import 'support/fake_adapter.dart';

void main() {
  Future<TfFramework> framework() => TfFramework.initialize(
    designSystems: const [Material3DesignSystem(), LiquidGlassDesignSystem(warmUpShaders: false)],
    store: TfMemoryPreferenceStore(),
    settingsBuilder: appSettings,
  );

  testWidgets('没有账号时提示登录，可切换到蹭缝与设置', (tester) async {
    final fw = await framework();
    final app = ZiplinerApp(
      framework: fw,
      services: AppServices.inMemory(fw.preferences, sklandAdapter: FakeAdapter(sklandResponder)),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('登录后才能连接坐标同步'), findsOneWidget);
    expect(find.text('登录'), findsWidgets);
    expect(find.text('欢迎使用终末地坐标工具'), findsOneWidget);
    expect(find.text('token 管理'), findsNothing);
    expect(find.text('账号管理'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('请求速度'), 150, scrollable: find.byType(Scrollable).first);
    expect(find.text('主动刷新坐标'), findsOneWidget);

    await tester.tap(find.text('蹭缝').last);
    await tester.pumpAndSettle();
    expect(find.text('等待 websocket 坐标'), findsOneWidget);

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.text('请求速度'), findsNothing);
    await tester.scrollUntilVisible(find.text('复制诊断信息'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('使用帮助'), findsOneWidget);
    expect(find.text('复制诊断信息'), findsOneWidget);
  });

  testWidgets('浮窗期间暂缓更新提示，返回后提示一次，取消后不重复弹出', (tester) async {
    final fw = await framework();
    final base = AppServices.inMemory(fw.preferences, sklandAdapter: FakeAdapter(sklandResponder));
    final updates = UpdateChecker(
      currentVersion: 'v0.1.3',
      dio: Dio()
        ..httpClientAdapter = FakeAdapter(
          (_) => FakeResponse.json({
            'tag_name': 'v0.2.0',
            'html_url': 'https://github.com/ZipField/zipliner-client/releases/tag/v0.2.0',
          }),
        ),
    );
    final overlay = DesktopOverlay(fw.preferences)..active = true;
    final services = AppServices(
      client: base.client,
      skland: base.skland,
      tokens: base.tokens,
      monitor: base.monitor,
      updates: updates,
      overlay: overlay,
      dataDirectory: base.dataDirectory,
    );
    await tester.pumpWidget(ZiplinerApp(framework: fw, services: services));
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(updates.available?.version, 'v0.2.0');
    expect(find.text('发现新版本 v0.2.0'), findsNothing);
    overlay.active = false;
    await overlay.refresh();
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v0.2.0'), findsOneWidget);
    expect(find.text('去下载'), findsWidgets);
    await tester.tap(find.text('以后再说'));
    await tester.pumpAndSettle();
    await tester.runAsync(updates.check);
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v0.2.0'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    updates.dispose();
    overlay.dispose();
    base.dispose();
  });

  testWidgets('有账号时连接并显示坐标', (tester) async {
    final fw = await framework();
    final socket = FakeSocket();
    final services = AppServices.inMemory(
      fw.preferences,
      sklandAdapter: FakeAdapter(sklandResponder),
      socketFactory: () => socket,
      tokens: const [token],
    );

    await tester.pumpWidget(ZiplinerApp(framework: fw, services: services));
    for (var i = 0; i < 100 && socket.token == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(socket.token, 'ws-token', reason: services.monitor.status);
    socket.push(-12.5, 88, 3.25);
    await tester.pumpAndSettle();

    expect(find.text('坐标已更新'), findsOneWidget);
    expect(find.text('-12.5'), findsOneWidget);
    expect(find.text('3.25'), findsOneWidget);
    expect(find.textContaining('官服 - 管理员'), findsOneWidget);

    await services.monitor.disconnect();
    await tester.pumpAndSettle();
  });
}
