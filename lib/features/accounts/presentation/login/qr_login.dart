import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/application/game_account_login_client.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

import 'package:zipliner_client/features/accounts/presentation/login/login_error.dart';

class QrLogin extends StatefulWidget {
  const QrLogin({super.key, required this.client, required this.onToken});

  final GameAccountLoginClient client;

  final void Function(String? token) onToken;

  @override
  State<QrLogin> createState() => _QrLoginState();
}

class _QrLoginState extends State<QrLogin> {
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
    final client = widget.client;
    try {
      final session = await client.createQrSession();
      if (!mounted || generation != _generation) return;
      setState(() {
        _session = session;
        _status = '请使用森空岛扫码';
      });
      _timer = Timer.periodic(_pollInterval, (_) => _poll(generation, session));
    } catch (e) {
      if (mounted && generation == _generation) {
        _fail(loginErrorMessage(e, '扫码登录失败'));
      }
    }
  }

  Future<void> _poll(int generation, QrSession session) async {
    if (_polling) return;
    _polling = true;
    try {
      final status = await widget.client.pollQrStatus(session.scanId);
      if (!mounted || generation != _generation) return;
      switch (status.state) {
        case QrState.pendingScan:
        case QrState.pendingConfirm:
          setState(
            () => _status =
                status.message ??
                (status.state == QrState.pendingScan ? '等待扫码' : '等待确认'),
          );
        case QrState.confirmed:
          _timer?.cancel();
          setState(() => _status = '已确认，正在登录...');
          widget.onToken(status.token ?? '');
        case QrState.error:
          _fail(status.message ?? '扫码状态异常');
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        _fail(loginErrorMessage(e, '扫码登录失败'));
      }
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
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: QrImageView(
                        data: session.scanUrl,
                        errorCorrectionLevel: QrErrorCorrectLevel.Q,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Text(
            _status,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _error ? Theme.of(context).colorScheme.error : null,
            ),
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
              : TfButton.secondary(
                  label: '刷新二维码',
                  icon: Icons.refresh,
                  onPressed: _start,
                ),
        ],
      ),
    );
  }
}
