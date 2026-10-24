import 'package:zipliner_client/app/app_scope.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

import 'package:zipliner_client/features/accounts/presentation/login/login_page.dart';
import 'package:zipliner_client/features/accounts/models/login_result.dart';
import 'package:zipliner_client/features/accounts/presentation/login/login_error.dart';

/// 打开登录页，成功后保存 token 并重新连接。返回是否新增了账号。
Future<bool> addAccount(
  BuildContext context, {
  TokenRepository? repository,
  bool reconnect = true,
}) async {
  final services = AppScope.of(context);
  final result = await Navigator.of(context)
      .push<LoginResult>(MaterialPageRoute(builder: (_) => const LoginPage()));
  if (result == null) return false;
  await (repository ?? services.tokens).add(result.token, result.region);
  if (reconnect) unawaited(services.monitor.start());
  if (context.mounted) showTfToast(context, '登录成功', type: TfToastType.success);
  return true;
}

/// 登录失效的账号重新登录，替换原来的凭据。返回是否成功。
Future<bool> reloginAccount(
  BuildContext context,
  StoredToken account, {
  TokenRepository? repository,
  bool reconnect = true,
  List<RoleSession> expectedRoles = const [],
}) async {
  final services = AppScope.of(context);
  final result = await Navigator.of(context).push<LoginResult>(
    MaterialPageRoute(
      builder: (_) => LoginPage(initialRegion: account.region, title: '重新登录'),
    ),
  );
  if (result == null) return false;
  try {
    if (result.region != account.region) {
      throw const SklandException('请登录原账号所在的区服。');
    }
    final knownRoles = expectedRoles.isNotEmpty
        ? expectedRoles
        : services.monitor.roles.where((r) => r.tokenId == account.id).toList();
    final fresh = await services.skland.login(result.token, result.region);
    String? originalId;
    try {
      originalId = (await services.skland.login(
        account.token,
        account.region,
      )).userId;
    } on SklandException {
      /* Expired credentials may still have cached role IDs. */
    }
    var matches = originalId != null && originalId == fresh.userId;
    if (originalId == null) {
      // A restarted client may have no live roles after the old token expires.
      // The migrated guest profile still retains previously selected role IDs.
      final expectedKeys = {for (final role in knownRoles) role.key};
      final guest = services.accounts?.guest;
      final remembered = [
        await guest?.role(),
        await guest?.defaultRoleFor(account.id),
      ];
      for (final key in remembered) {
        if (key != null && key.startsWith('${account.id}:')) {
          expectedKeys.add(key);
        }
      }
      final bindings = await services.skland.getRoleBindings(
        fresh,
        result.region,
      );
      matches = bindings.any(
        (b) => expectedKeys.contains('${account.id}:${b.serverId}:${b.roleId}'),
      );
    }
    if (!matches) {
      throw const SklandException('无法确认登录的是原账号，原凭据未更改。请使用原账号登录，或在账号管理中新增账号。');
    }
  } catch (error) {
    if (context.mounted) {
      showTfToast(
        context,
        loginErrorMessage(error, '无法确认账号身份，原凭据未更改。'),
        type: TfToastType.error,
      );
    }
    return false;
  }
  await (repository ?? services.tokens).replace(
    account.id,
    result.token,
    result.region,
  );
  if (reconnect) unawaited(services.monitor.start());
  if (context.mounted) {
    showTfToast(context, '重新登录成功', type: TfToastType.success);
  }
  return true;
}
