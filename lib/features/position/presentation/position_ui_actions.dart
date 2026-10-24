import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/presentation/account_manager_page.dart';

Future<void> copyPositionText(BuildContext context, String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      showTfToast(context, '已复制到剪贴板', type: TfToastType.success);
    }
  } catch (_) {
    if (context.mounted) {
      showTfToast(context, '复制失败，剪贴板可能正被其他程序占用，请稍后重试', type: TfToastType.error);
    }
  }
}

void openPositionAccounts(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AccountManagerPage()));
