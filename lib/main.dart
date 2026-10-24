import 'package:zipliner_client/app/bootstrap.dart';
import 'package:zipliner_client/app/startup.dart';

import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:zipliner_client/app/app.dart';
import 'package:zipliner_client/shared/logging/app_log.dart';
import 'package:zipliner_client/platform/desktop/single_instance.dart';
import 'package:zipliner_client/features/overlay/coordinate_window_entry.dart';
import 'package:zipliner_client/platform/desktop/client_widgets_binding.dart';

Future<void> main(List<String> arguments) async {
  ClientWidgetsBinding();

  if (arguments.firstOrNull == '--coordinate-window') {
    try {
      await runCoordinateWindow(arguments);
    } catch (error, stack) {
      stderr.writeln('Coordinate window failed: $error\n$stack');
      exit(1);
    }
    return;
  }

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
          child: Text(
            '这里出了点问题。请到“设置 → 复制诊断信息”，然后在项目主页反馈。',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  runApp(
    ClientStartup(
      load: () async {
        final (framework, services) = await bootstrap();
        return ZiplinerApp(framework: framework, services: services);
      },
    ),
  );
}
