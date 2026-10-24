import 'package:zipliner_client/app/app_scope.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:zipliner_client/app/app_services.dart';
import 'package:zipliner_client/shared/logging/app_log.dart';
import 'package:zipliner_client/app/home_shell.dart';
import 'package:zipliner_client/features/accounts/application/client_accounts.dart';

class AccountGate extends StatefulWidget {
  const AccountGate({super.key});
  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> with WindowListener {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  AppServices? _services;
  bool _closing = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services != null) return;
    _services = AppScope.of(context);
    if (Platform.isWindows) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    // Network restoration and the display process must not delay the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closing) return;
      unawaited(_initialize());
    });
  }

  Future<void> _initialize() async {
    final watch = Stopwatch()..start();
    await Future.wait<void>([
      if (_services!.accounts != null) _services!.accounts!.initialize(),
      () async {
        try {
          await _services!.overlay?.initialize();
        } catch (error, stack) {
          AppLog.instance.error('悬浮窗初始化失败', error, stack);
        }
      }(),
    ]);
    AppLog.instance.info('后台初始化完成：${watch.elapsedMilliseconds} ms');
  }

  @override
  void onWindowClose() {
    if (Platform.isWindows) unawaited(_exit());
  }

  Future<void> _exit() async {
    if (_closing || !mounted) return;
    _closing = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    final progress = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('正在退出…'),
          content: SizedBox(
            width: 360,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                SizedBox(width: 20),
                Expanded(child: Text('正在断开连接并清理网络资源，请稍候。')),
              ],
            ),
          ),
        ),
      ),
    );
    unawaited(navigator.push(progress));
    // Paint the progress dialog before beginning any native cleanup work.
    await WidgetsBinding.instance.endOfFrame;
    final watch = Stopwatch()..start();
    try {
      await Future.wait<void>([
        _services!.weakNetwork.shutdown(),
        () async {
          try {
            await _services!.monitor.disconnect();
          } catch (error, stack) {
            AppLog.instance.error('退出时断开定位失败', error, stack);
          }
        }(),
      ]);
    } catch (error) {
      if (!mounted) return;
      if (progress.isActive) navigator.removeRoute(progress);
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('网络驱动未能完全退出'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Text('弱网已停止，但驱动卸载未完成。请退出其他网络工具，必要时重启电脑完成清理。\n\n$error'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('留在客户端'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出并稍后重启电脑'),
            ),
          ],
        ),
      );
      if (leave != true) {
        _closing = false;
        return;
      }
    }
    // Preserve the saved visibility setting while closing the child process.
    try {
      await _services!.overlay?.shutdown();
    } catch (error, stack) {
      AppLog.instance.error('退出时关闭坐标悬浮窗失败', error, stack);
      // The display also exits when it detects its parent has terminated.
    }
    AppLog.instance.info('退出清理完成：${watch.elapsedMilliseconds} ms');
    // Let WM_CLOSE destroy the window and engine before the message loop exits.
    // window_manager.destroy() only posts WM_QUIT on Windows.
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = AppScope.of(context).accounts;
    if (accounts == null) return const HomeShell();
    return ListenableBuilder(
      listenable: accounts,
      builder: (context, _) {
        if (accounts.initialized && accounts.mode != ClientAccountMode.choose) {
          return HomeShell(key: ValueKey(accounts.profileId));
        }
        return Scaffold(
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Zipliner Client',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '登录 Zipliner，同步绑定账号并与网站共享实时定位。也可以选择本地模式，凭据仅保存在本机。',
                    ),
                    const SizedBox(height: 24),
                    if (accounts.initialized) ...[
                      TextField(
                        controller: _identifier,
                        enabled: !accounts.busy,
                        decoration: const InputDecoration(labelText: '邮箱或用户名'),
                        autofillHints: const [AutofillHints.username],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        enabled: !accounts.busy,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '密码'),
                        autofillHints: const [AutofillHints.password],
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: accounts.busy
                            ? null
                            : () async {
                                await accounts.login(
                                  _identifier.text,
                                  _password.text,
                                );
                                _password.clear();
                              },
                        child: const Text('登录 Zipliner'),
                      ),
                      TextButton(
                        onPressed: accounts.busy ? null : accounts.enterGuest,
                        child: const Text('使用本地模式'),
                      ),
                    ],
                    if (accounts.error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          accounts.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (!accounts.initialized && accounts.busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Text('正在启动，请稍候…'),
                          ],
                        ),
                      ),
                    if (!accounts.initialized && !accounts.busy)
                      FilledButton(
                        onPressed: accounts.initialize,
                        child: const Text('重试读取本地档案'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
