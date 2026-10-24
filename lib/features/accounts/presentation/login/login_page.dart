import 'package:zipliner_client/app/app_scope.dart';
import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/application/game_account_login_client.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

import 'package:zipliner_client/features/accounts/models/login_result.dart';
import 'package:zipliner_client/features/accounts/presentation/login/qr_login.dart';
import 'package:zipliner_client/features/accounts/presentation/login/phone_code_login.dart';
import 'package:zipliner_client/features/accounts/presentation/login/skport_login.dart';

enum _Method {
  qr('扫码', Icons.qr_code_2),
  code('验证码', Icons.sms_outlined),
  skport('SKPort', Icons.public);

  const _Method(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 登录森空岛 / SKPort 获取账号凭据，对应原工具的 `LoginWindow`。
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    this.initialRegion = SklandRegion.skland,
    this.bindToCloud = false,
    this.reauthenticateAccountId,
    this.title = '登录',
  });

  final bool bindToCloud;
  final String? reauthenticateAccountId;
  final SklandRegion initialRegion;
  final String title;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late _Method _method = widget.initialRegion.isSkport
      ? _Method.skport
      : _Method.qr;

  void _done(String? token, SklandRegion region) {
    if (widget.bindToCloud) {
      Navigator.of(context).pop<bool>(true);
      return;
    }
    final trimmed = token?.trim() ?? '';
    if (trimmed.isEmpty) throw const SklandException('登录失败');
    Navigator.of(context).pop<LoginResult>((token: trimmed, region: region));
  }

  @override
  Widget build(BuildContext context) {
    final login = GameAccountLoginClient(
      AppScope.of(context),
      cloud: widget.bindToCloud,
      reauthenticateAccountId: widget.reauthenticateAccountId,
    );
    return TfScaffold(
      title: widget.title,
      body: TfListView(
        maxWidth: 480,
        children: [
          Text(
            '国服玩家推荐用森空岛 App 扫码登录；国际服玩家请选择“SKPort”。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          TfSegmentedControl<_Method>(
            segments: [
              for (final m in _Method.values)
                TfSegment(value: m, label: m.label, icon: m.icon),
            ],
            selected: _method,
            onChanged: (m) => setState(() => _method = m),
          ),
          switch (_method) {
            _Method.qr => QrLogin(
              client: login,
              onToken: (t) => _done(t, SklandRegion.skland),
            ),
            _Method.code => PhoneCodeLogin(
              client: login,
              onToken: (t) => _done(t, SklandRegion.skland),
            ),
            _Method.skport => SkportLogin(
              key: const ValueKey('skport'),
              client: login,
              onToken: (t) => _done(t, SklandRegion.skport),
            ),
          },
          Text(
            widget.bindToCloud
                ? '账号将绑定到当前 Zipliner 账号，凭据加密保存在 Zipliner，用于共享实时定位。'
                : '登录信息直接发送给鹰角 / 森空岛，账号凭据用系统加密只保存在本机，不会上传到任何第三方服务器。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
