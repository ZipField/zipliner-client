import 'app_scope.dart';

import 'package:zipliner_client/features/accounts/presentation/account_gate.dart';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/app/app_info.dart';
import 'package:zipliner_client/app/app_services.dart';
import 'package:zipliner_client/app/app_theme.dart';

class ZiplinerApp extends StatelessWidget {
  const ZiplinerApp({
    super.key,
    required this.framework,
    required this.services,
  });

  final TfFramework framework;
  final AppServices services;

  @override
  Widget build(BuildContext context) => AppScope(
    services: services,
    child: TfApp(
      framework: framework,
      title: AppInfo.name,
      locale: const Locale('zh'),
      home: const AccountGate(),
      builder: (context, child) => Theme(
        data: refineTheme(Theme.of(context)),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}
