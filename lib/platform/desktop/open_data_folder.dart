import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zipliner_client/shared/logging/app_log.dart';

final _openingFolders = <String>{};
final _lastFolderRequests = <String, DateTime>{};

Future<void> openDataFolder(BuildContext context, String path) async {
  final now = DateTime.now();
  final last = _lastFolderRequests[path];
  if (_openingFolders.contains(path) ||
      (last != null && now.difference(last) < const Duration(seconds: 1))) {
    return;
  }
  _openingFolders.add(path);
  _lastFolderRequests[path] = now;
  try {
    await Directory(path)
        .create(recursive: true)
        .timeout(const Duration(seconds: 5));
    if (Platform.isWindows) {
      // Launch Explorer asynchronously instead of calling ShellExecute through
      // url_launcher on the UI thread. Never wait for Explorer to exit.
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      await Process.start('$systemRoot\\explorer.exe', [
        Directory(path).absolute.path,
      ], mode: ProcessStartMode.detached).timeout(const Duration(seconds: 5));
    } else {
      final ok = await launchUrl(
        Uri.directory(path),
        mode: LaunchMode.externalApplication,
      ).timeout(const Duration(seconds: 5));
      if (!ok) throw StateError('文件夹未能打开');
    }
  } catch (error, stack) {
    AppLog.instance.error('打开数据文件夹失败', error, stack);
    if (!context.mounted) return;
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: path))
          .timeout(const Duration(seconds: 2));
      copied = true;
    } catch (_) {
      // Opening a folder must not leave the settings action waiting forever.
    }
    if (context.mounted) {
      showTfToast(
        context,
        copied ? '无法打开文件夹，路径已复制到剪贴板' : '无法打开文件夹，请按所示路径手动打开',
        type: TfToastType.warning,
      );
    }
  } finally {
    _openingFolders.remove(path);
  }
}
