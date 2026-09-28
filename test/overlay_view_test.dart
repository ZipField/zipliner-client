import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/core/services.dart';
import 'package:zipliner_client/desktop/desktop_overlay.dart';
import 'package:zipliner_client/desktop/game_window_locator.dart';
import 'package:zipliner_client/desktop/overlay_view.dart';
import 'package:zipliner_client/position/position_prefs.dart';
import 'package:zipliner_client/skland/skland_models.dart';

// Render the real overlay without a game process or native window operations.
class _Locator extends GameWindowLocator {
  @override
  bool get isSupported => true;
}

void main() {
  for (final system in const [Material3DesignSystem(), LiquidGlassDesignSystem(warmUpShaders: false)]) {
    for (final theme in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('${system.id} $theme: 浮窗复用框架且适应大小、精度、跟随模式', (tester) async {
        final fw = await TfFramework.initialize(designSystems: [system], store: TfMemoryPreferenceStore());
        await fw.preferences.setEnum(TfPreferenceKeys.themeMode, theme);
        await fw.preferences.set(TfPreferenceKeys.textScale, 1.6);
        final services = AppServices.inMemory(fw.preferences);
        final overlay = DesktopOverlay(fw.preferences, locator: _Locator());
        services.monitor.position = const PositionSnapshot(-123456.78912, -0.00001, 32.125);
        addTearDown(services.dispose);
        addTearDown(overlay.dispose);

        for (final follow in [false, true]) {
          await fw.preferences.set(PositionPrefs.followGame, follow);
          for (final scale in [1.0, 1.2, 1.4]) {
            await fw.preferences.set(PositionPrefs.overlayScale, scale);
            await fw.preferences.set(PositionPrefs.overlayDecimals, 3);
            overlay.warning = follow ? '未找到游戏窗口' : null;
            await tester.pumpWidget(
              TfApp(
                framework: fw,
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox.fromSize(
                      size: overlay.windowSize,
                      child: OverlayView(overlay: overlay, monitor: services.monitor),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('-123456.789'), findsOneWidget);
            expect(find.text('0.000'), findsOneWidget);
            expect(find.byType(TfCard), follow ? findsNothing : findsOneWidget);
            expect(find.byIcon(Icons.open_in_full), findsOneWidget);
            if (follow) expect(find.text('未找到游戏窗口'), findsOneWidget);
          }
        }
        await fw.preferences.set(PositionPrefs.overlayDecimals, 5);
        await overlay.refresh();
        await tester.pumpAndSettle();
        expect(find.text('-123456.78912'), findsOneWidget);

        final heightWithoutTarget = overlay.windowSize.height;
        await PositionPrefs.setTarget(
          fw.preferences,
          (x: -123453.78912, y: 3.99999, z: 44.125),
        );
        await overlay.refresh();
        await tester.pumpAndSettle();
        expect(overlay.windowSize.height, greaterThan(heightWithoutTarget));
        expect(find.text('目标'), findsOneWidget);
        expect(find.text('13.00 m'), findsOneWidget);
        expect(find.textContaining('-123453.78912'), findsOneWidget);

        await PositionPrefs.clearTarget(fw.preferences);
        await overlay.refresh();
        await tester.pumpAndSettle();
        expect(find.text('目标'), findsNothing);

        services.monitor.position = null;
        services.monitor.status = '等待坐标';
        await fw.preferences.set(PositionPrefs.overlayDecimals, 0);
        await overlay.refresh();
        await tester.pumpAndSettle();
        expect(find.text('等待坐标'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
