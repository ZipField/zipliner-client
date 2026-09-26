import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_log.dart';
import 'desktop/single_instance.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 调试时热重启会重新执行 main，所以只在发布版里限制单实例。
  if (kReleaseMode && !SingleInstance.acquire()) {
    SingleInstance.activateExisting();
    exit(0);
  }

  FlutterError.onError = (details) {
    AppLog.instance.error('界面异常', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.error('未处理的异常', error, stack);
    return true;
  };
  if (kReleaseMode) {
    ErrorWidget.builder = (details) => const Material(
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('这里出了点问题。请到“设置 → 复制诊断信息”，然后在项目主页反馈。', textAlign: TextAlign.center),
        ),
      ),
    );
  }

  final (framework, services) = await bootstrap();
  runApp(ZiplinerApp(framework: framework, services: services));
}
