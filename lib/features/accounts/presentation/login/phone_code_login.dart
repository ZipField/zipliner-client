import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/application/game_account_login_client.dart';

import 'package:zipliner_client/features/accounts/presentation/login/login_error.dart';
import 'package:zipliner_client/features/accounts/presentation/login/login_form_widgets.dart';

class PhoneCodeLogin extends StatefulWidget {
  const PhoneCodeLogin({
    super.key,
    required this.client,
    required this.onToken,
  });

  final GameAccountLoginClient client;

  final void Function(String? token) onToken;

  @override
  State<PhoneCodeLogin> createState() => _PhoneCodeLoginState();
}

class _PhoneCodeLoginState extends State<PhoneCodeLogin> {
  static const _cooldown = 60;

  final _phone = TextEditingController();
  final _code = TextEditingController();
  String? _message;
  bool _error = false;
  bool _busy = false;
  int _remaining = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  String? _validPhone() {
    final phone = _phone.text.trim();
    if (!RegExp(r'^\d{11}$').hasMatch(phone)) {
      _show('请输入 11 位数字手机号', error: true);
      return null;
    }
    return phone;
  }

  void _show(String message, {bool error = false}) => setState(() {
    _message = message;
    _error = error;
  });

  Future<void> _send() async {
    final phone = _validPhone();
    if (phone == null) return;
    setState(() => _busy = true);
    _show('正在发送验证码...');
    try {
      await widget.client.sendPhoneCode(phone);
      if (!mounted) return;
      _show('验证码已发送');
      _remaining = _cooldown;
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return timer.cancel();
        setState(() => _remaining--);
        if (_remaining <= 0) timer.cancel();
      });
    } catch (e) {
      if (mounted) _show(loginErrorMessage(e, '发送验证码失败'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    final phone = _validPhone();
    if (phone == null) return;
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return _show('请输入 6 位数字验证码', error: true);
    }
    setState(() => _busy = true);
    _show('正在登录...');
    try {
      final token = await widget.client.phoneCodeLogin(phone, code);
      if (mounted) widget.onToken(token);
    } catch (e) {
      if (mounted) _show(loginErrorMessage(e, '手机验证码登录失败'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => LoginFormCard(
    children: [
      TfTextField(
        controller: _phone,
        placeholder: '手机号',
        prefixIcon: Icons.phone_android,
        keyboardType: TextInputType.phone,
        autofillHints: const [AutofillHints.telephoneNumber],
        textInputAction: TextInputAction.next,
      ),
      Row(
        children: [
          Expanded(
            child: TfTextField(
              controller: _code,
              placeholder: '验证码',
              prefixIcon: Icons.pin_outlined,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              onSubmitted: (_) => _login(),
            ),
          ),
          const SizedBox(width: 8),
          TfButton.secondary(
            label: _remaining > 0 ? '$_remaining 秒' : '发送验证码',
            onPressed: _busy || _remaining > 0 ? null : _send,
          ),
        ],
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
