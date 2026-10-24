import 'package:zipliner_client/app/app_scope.dart';
import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zipliner_client/features/settings/application/update_checker.dart';

/// 检查更新；[silent] 为 true 时只在有新版本时提示。
Future<void> checkForUpdates(BuildContext context, {bool silent = true}) async {
  final updates = AppScope.of(context).updates;
  final info = await updates.check();
  if (!context.mounted) return;
  if (info == null) {
    if (!silent) showTfToast(context, updates.lastResult ?? '已是最新版本');
    return;
  }
  await presentUpdatePrompt(context, info, automatic: silent);
}

Future<void> presentUpdatePrompt(
  BuildContext context,
  UpdateInfo info, {
  bool automatic = false,
}) async {
  final services = AppScope.of(context);
  final updates = services.updates;
  if (updates.promptOpen ||
      (automatic &&
          (updates.lastPromptedVersion == info.version ||
              services.overlay?.active == true))) {
    return;
  }
  updates.promptOpen = true;
  updates.lastPromptedVersion = info.version;
  try {
    final open = await showTfConfirm(
      context,
      title: '发现新版本 ${info.version}',
      message:
          '当前版本 ${updates.currentVersion}。打开下载页面下载新版本后，解压覆盖旧文件即可，账号和设置都会保留。',
      confirmLabel: '去下载',
      cancelLabel: '以后再说',
    );
    if (open) await launchUrl(Uri.parse(info.url));
  } finally {
    updates.promptOpen = false;
  }
}
