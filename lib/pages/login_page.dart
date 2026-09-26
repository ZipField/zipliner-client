import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tf_framework/tf_framework.dart';

import '../core/services.dart';
import '../position/token_store.dart';
import '../skland/skland_models.dart';

typedef LoginResult = ({String token, SklandRegion region});

/// 打开登录页，成功后保存 token 并重新连接。返回是否新增了账号。
Future<bool> addAccount(BuildContext context) async {
  final services = AppServices.of(context);
  final result = await Navigator.of(context).push<LoginResult>(MaterialPageRoute(builder: (_) => const LoginPage()));
  if (result == null) return false;
  await services.tokens.add(result.token, result.region);
  unawaited(services.monitor.start());
  if (context.mounted) showTfToast(context, '登录成功', type: TfToastType.success);
  return true;
}

/// 登录失效的账号重新登录，替换原来的凭据。返回是否成功。
Future<bool> reloginAccount(BuildContext context, StoredToken account) async {
  final services = AppServices.of(context);
  final result = await Navigator.of(context).push<LoginResult>(
    MaterialPageRoute(
      builder: (_) => LoginPage(initialRegion: account.region, title: '重新登录'),
    ),
  );
  if (result == null) return false;
  await services.tokens.replace(account.id, result.token, result.region);
  unawaited(services.monitor.start());
  if (context.mounted) showTfToast(context, '重新登录成功', type: TfToastType.success);
  return true;
}

enum _Method {
  qr('扫码', Icons.qr_code_2),
  code('验证码', Icons.sms_outlined),
  password('密码', Icons.password),
  skport('SKPort', Icons.public);

  const _Method(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 登录森空岛 / SKPort 获取账号凭据，对应原工具的 `LoginWindow`。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.initialRegion = SklandRegion.skland, this.title = '登录'});

  final SklandRegion initialRegion;
  final String title;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late _Method _method = widget.initialRegion.isSkport ? _Method.skport : _Method.qr;

  void _done(String token, SklandRegion region) {
    final trimmed = token.trim();
    if (trimmed.isEmpty) throw const SklandException('登录失败');
    Navigator.of(context).pop<LoginResult>((token: trimmed, region: region));
  }

  @override
  Widget build(BuildContext context) => TfScaffold(
    title: widget.title,
    body: TfListView(
      maxWidth: 480,
      children: [
        Text('国服玩家推荐用森空岛 App 扫码登录；国际服玩家请选择“SKPort”。', style: Theme.of(context).textTheme.bodyMedium),
        TfSegmentedControl<_Method>(
          segments: [for (final m in _Method.values) TfSegment(value: m, label: m.label, icon: m.icon)],
          selected: _method,
          onChanged: (m) => setState(() => _method = m),
        ),
        switch (_method) {
          _Method.qr => _QrLogin(onToken: (t) => _done(t, SklandRegion.skland)),
          _Method.code => _PhoneCodeLogin(onToken: (t) => _done(t, SklandRegion.skland)),
          _Method.password => _PasswordLogin(
            key: const ValueKey('password'),
            region: SklandRegion.skland,
            onToken: (t) => _done(t, SklandRegion.skland),
          ),
          _Method.skport => _PasswordLogin(
            key: const ValueKey('skport'),
            region: SklandRegion.skport,
            onToken: (t) => _done(t, SklandRegion.skport),
          ),
        },
        Text('登录信息直接发送给鹰角 / 森空岛，账号凭据用系统加密只保存在本机，不会上传到任何第三方服务器。', style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

String _messageOf(Object error, String fallback) => error is SklandException ? error.message : fallback;

class _QrLogin extends StatefulWidget {
  const _QrLogin({required this.onToken});

  final void Function(String token) onToken;

  @override
  State<_QrLogin> createState() => _QrLoginState();
}

class _QrLoginState extends State<_QrLogin> {
  static const _pollInterval = Duration(milliseconds: 1500);

  QrSession? _session;
  String _status = '正在生成二维码...';
  bool _error = false;
  Timer? _timer;
  bool _polling = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _timer?.cancel();
    setState(() {
      _session = null;
      _status = '正在生成二维码...';
      _error = false;
    });
    final client = AppServices.of(context).skland;
    try {
      final session = await client.createQrSession();
      if (!mounted || generation != _generation) return;
      setState(() {
        _session = session;
        _status = '请使用森空岛扫码';
      });
      _timer = Timer.periodic(_pollInterval, (_) => _poll(generation, session));
    } catch (e) {
      if (mounted && generation == _generation) _fail(_messageOf(e, '扫码登录失败'));
    }
  }

  Future<void> _poll(int generation, QrSession session) async {
    if (_polling) return;
    _polling = true;
    try {
      final status = await AppServices.of(context).skland.pollQrStatus(session.scanId);
      if (!mounted || generation != _generation) return;
      switch (status.state) {
        case QrState.pendingScan:
        case QrState.pendingConfirm:
          setState(() => _status = status.message ?? (status.state == QrState.pendingScan ? '等待扫码' : '等待确认'));
        case QrState.confirmed:
          _timer?.cancel();
          setState(() => _status = '已确认，正在登录...');
          widget.onToken(status.token ?? '');
        case QrState.error:
          _fail(status.message ?? '扫码状态异常');
      }
    } catch (e) {
      if (mounted && generation == _generation) _fail(_messageOf(e, '扫码登录失败'));
    } finally {
      _polling = false;
    }
  }

  void _fail(String message) {
    _timer?.cancel();
    setState(() {
      _status = message;
      _error = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return TfCard(
      child: Column(
        children: [
          SizedBox.square(
            dimension: 226,
            child: session == null
                ? const Center(child: TfProgress.circular())
                : DecoratedBox(
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: QrImageView(data: session.scanUrl, errorCorrectionLevel: QrErrorCorrectLevel.Q),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Text(
            _status,
            textAlign: TextAlign.center,
            style: TextStyle(color: _error ? Theme.of(context).colorScheme.error : null),
          ),
          const SizedBox(height: 4),
          Text(
            '打开森空岛 App，点首页左上角的“扫一扫”，扫描上面的二维码并在手机上确认。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _error
              ? TfButton(label: '刷新二维码', icon: Icons.refresh, onPressed: _start)
              : TfButton.secondary(label: '刷新二维码', icon: Icons.refresh, onPressed: _start),
        ],
      ),
    );
  }
}

class _PhoneCodeLogin extends StatefulWidget {
  const _PhoneCodeLogin({required this.onToken});

  final void Function(String token) onToken;

  @override
  State<_PhoneCodeLogin> createState() => _PhoneCodeLoginState();
}

class _PhoneCodeLoginState extends State<_PhoneCodeLogin> {
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
      await AppServices.of(context).skland.sendPhoneCode(phone);
      if (!mounted) return;
      _show('验证码已发送');
      _remaining = _cooldown;
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return timer.cancel();
        setState(() => _remaining--);
        if (_remaining <= 0) timer.cancel();
      });
    } catch (e) {
      if (mounted) _show(_messageOf(e, '发送验证码失败'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    final phone = _validPhone();
    if (phone == null) return;
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) return _show('请输入 6 位数字验证码', error: true);
    setState(() => _busy = true);
    _show('正在登录...');
    try {
      final token = await AppServices.of(context).skland.phoneCodeLogin(phone, code);
      if (mounted) widget.onToken(token);
    } catch (e) {
      if (mounted) _show(_messageOf(e, '手机验证码登录失败'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _FormCard(
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
      if (_message != null) _StatusLine(message: _message!, error: _error),
      TfButton(label: '登录', icon: Icons.login, expanded: true, loading: _busy, onPressed: _login),
    ],
  );
}

class _PasswordLogin extends StatefulWidget {
  const _PasswordLogin({super.key, required this.region, required this.onToken});

  final SklandRegion region;
  final void Function(String token) onToken;

  @override
  State<_PasswordLogin> createState() => _PasswordLoginState();
}

class _PasswordLoginState extends State<_PasswordLogin> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String? _message;
  bool _error = false;
  bool _busy = false;

  bool get _email => widget.region.isSkport;

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final account = _account.text.trim();
    final password = _password.text;
    if (_email ? !account.contains('@') : !RegExp(r'^\d{11}$').hasMatch(account)) {
      return _show(_email ? '请输入邮箱' : '请输入 11 位数字手机号', error: true);
    }
    if (password.isEmpty) return _show('请输入密码', error: true);
    setState(() => _busy = true);
    _show('正在登录...');
    final client = AppServices.of(context).skland;
    try {
      final token = _email
          ? await client.emailPasswordLogin(account, password)
          : await client.phonePasswordLogin(account, password);
      if (mounted) widget.onToken(token);
    } catch (e) {
      if (mounted) _show(_messageOf(e, _email ? '邮箱密码登录失败' : '帐号密码登录失败'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String message, {bool error = false}) => setState(() {
    _message = message;
    _error = error;
  });

  @override
  Widget build(BuildContext context) => _FormCard(
    children: [
      if (_email) Text('SKPort 为国际服账号，使用 as.gryphline.com 登录。', style: Theme.of(context).textTheme.bodySmall),
      TfTextField(
        controller: _account,
        placeholder: _email ? '邮箱' : '手机号',
        prefixIcon: _email ? Icons.alternate_email : Icons.phone_android,
        keyboardType: _email ? TextInputType.emailAddress : TextInputType.phone,
        autofillHints: [_email ? AutofillHints.email : AutofillHints.telephoneNumber],
        textInputAction: TextInputAction.next,
      ),
      TfTextField(
        controller: _password,
        placeholder: '密码',
        prefixIcon: Icons.lock_outline,
        obscureText: _obscure,
        suffixIcon: _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        suffixTooltip: _obscure ? '显示密码' : '隐藏密码',
        onSuffixTap: () => setState(() => _obscure = !_obscure),
        autofillHints: const [AutofillHints.password],
        onSubmitted: (_) => _login(),
      ),
      if (_message != null) _StatusLine(message: _message!, error: _error),
      TfButton(label: '登录', icon: Icons.login, expanded: true, loading: _busy, onPressed: _login),
    ],
  );
}

class _FormCard extends StatelessWidget {
  const _FormCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => TfCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 12, children: children),
  );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.error});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Text(
    message,
    style: TextStyle(
      color: error ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
