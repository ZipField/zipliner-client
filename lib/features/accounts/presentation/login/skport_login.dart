import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/application/game_account_login_client.dart';

import 'package:zipliner_client/features/accounts/presentation/login/login_error.dart';
import 'package:zipliner_client/features/accounts/presentation/login/login_form_widgets.dart';

class SkportLogin extends StatefulWidget {
  const SkportLogin({super.key, required this.client, required this.onToken});

  final GameAccountLoginClient client;
  final void Function(String? token) onToken;

  @override
  State<SkportLogin> createState() => _SkportLoginState();
}

class _SkportLoginState extends State<SkportLogin> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String? _message;
  bool _error = false;
  bool _busy = false;

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final account = _account.text.trim();
    final password = _password.text;
    if (!account.contains('@')) {
      return _show('请输入邮箱', error: true);
    }
    if (password.isEmpty) return _show('请输入密码', error: true);
    setState(() => _busy = true);
    _show('正在登录...');
    final client = widget.client;
    try {
      final token = await client.emailPasswordLogin(account, password);
      if (mounted) widget.onToken(token);
    } catch (e) {
      if (mounted) _show(loginErrorMessage(e, '邮箱密码登录失败'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String message, {bool error = false}) => setState(() {
    _message = message;
    _error = error;
  });

  @override
  Widget build(BuildContext context) => LoginFormCard(
    children: [
      Text(
        'SKPort 为国际服账号，使用 as.gryphline.com 登录。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      TfTextField(
        controller: _account,
        placeholder: '邮箱',
        prefixIcon: Icons.alternate_email,
        keyboardType: TextInputType.emailAddress,
        autofillHints: [AutofillHints.email],
        textInputAction: TextInputAction.next,
      ),
      TfTextField(
        controller: _password,
        placeholder: '密码',
        prefixIcon: Icons.lock_outline,
        obscureText: _obscure,
        suffixIcon: _obscure
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
        suffixTooltip: _obscure ? '显示密码' : '隐藏密码',
        onSuffixTap: () => setState(() => _obscure = !_obscure),
        autofillHints: const [AutofillHints.password],
        onSubmitted: (_) => _login(),
      ),
      if (_message != null) LoginStatusLine(message: _message!, error: _error),
      TfButton(
        label: '登录',
        icon: Icons.login,
        expanded: true,
        loading: _busy,
        onPressed: _login,
      ),
    ],
  );
}
