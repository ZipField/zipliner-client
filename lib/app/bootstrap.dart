import 'dart:io';
import 'dart:ui';

import 'package:tf_framework/tf_framework.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zipliner_client/app/app_info.dart';
import 'package:zipliner_client/shared/logging/app_log.dart';
import 'package:zipliner_client/app/app_services.dart';

import 'package:zipliner_client/features/settings/presentation/app_settings.dart';

Future<(TfFramework, AppServices)> bootstrap() async {
  final watch = Stopwatch()..start();
  final framework = await TfFramework.initialize(
    designSystems: const [Material3DesignSystem(), LiquidGlassDesignSystem()],
    settingsBuilder: appSettings,
  );
  final dataDirectory = await AppServices.defaultDataDirectory();
  AppLog.instance
    ..attachFile(dataDirectory)
    ..info(
      '${AppInfo.name} ${AppInfo.version} 启动，${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
  final services = AppServices.create(
    framework.preferences,
    dataDirectory: dataDirectory,
    languageProvider: () =>
        apiLanguage(framework.preferences.get(TfPreferenceKeys.locale)),
  );
  try {
    if (Platform.isWindows || Platform.isLinux) {
      await windowManager.ensureInitialized();
      await windowManager.setTitle(AppInfo.name);
    }
  } catch (e, stack) {
    // 悬浮窗初始化失败不影响坐标同步本身。
    AppLog.instance.error('悬浮窗初始化失败', e, stack);
  }
  AppLog.instance.info('主界面基础初始化完成：${watch.elapsedMilliseconds} ms');
  return (framework, services);
}

/// 把框架的语言偏好（空串表示跟随系统）转换成服务端 `X-Language` 的取值。
String apiLanguage(String preference) {
  final code = preference.isNotEmpty
      ? preference
      : PlatformDispatcher.instance.locale.languageCode;
  return switch (code) {
    'en' => 'en-US',
    _ => 'zh-CN',
  };
}
