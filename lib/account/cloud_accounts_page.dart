import 'package:flutter/material.dart';

import '../pages/login_page.dart';
import '../skland/skland_models.dart';
import '../core/services.dart';

import 'package:tf_framework/tf_framework.dart';

Future<bool> bindCloudAccount(
  BuildContext context, {
  String? accountId,
  SklandRegion region = SklandRegion.skland,
}) async {
  if (accountId != null) {
    try {
      final data = await AppServices.of(context).accounts!.api.get(
        '/api/account/game-accounts/reauthentication-target',
        query: {'gameAccountId': accountId},
        auth: true,
      );
      if (data is! Map || data['scopedReauthentication'] != true) {
        throw const FormatException();
      }
    } catch (_) {
      if (context.mounted) {
        showTfToast(
          context,
          '服务器暂不支持此账号的安全重新登录，请更新后端后重试。',
          type: TfToastType.error,
        );
      }
      return false;
    }
    if (!context.mounted) return false;
  }
  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => LoginPage(
        bindToCloud: true,
        reauthenticateAccountId: accountId,
        initialRegion: region,
        title: accountId == null ? '绑定游戏账号' : '重新登录游戏账号',
      ),
    ),
  );
  return result == true;
}
