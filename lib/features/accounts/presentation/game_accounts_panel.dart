import 'package:zipliner_client/app/app_scope.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zipliner_client/features/accounts/presentation/local_account_actions.dart';
import 'package:zipliner_client/features/accounts/presentation/bound_account_actions.dart';
import 'package:zipliner_client/features/accounts/application/game_accounts_controller.dart';

import 'package:zipliner_client/features/accounts/presentation/game_account_row.dart';
import 'package:zipliner_client/features/accounts/presentation/game_account_dialog.dart';

class GameAccountsPanel extends StatefulWidget {
  const GameAccountsPanel({super.key, this.localOnly = false});
  final bool localOnly;
  @override
  State<GameAccountsPanel> createState() => _GameAccountsPanelState();
}

class _GameAccountsPanelState extends State<GameAccountsPanel> {
  GameAccountsController? _controller;
  bool _local = true;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final services = AppScope.of(context);
    _local =
        widget.localOnly ||
        services.accounts?.isCloud != true ||
        services.accounts!.useLocalCredentials;
    _controller = GameAccountsController(services);
    unawaited(_controller!.refresh(_local));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final controller = _controller!;
    final local = _local;
    final ok = local
        ? await addAccount(
            context,
            repository: controller.services.tokens,
            reconnect: false,
          )
        : await bindCloudAccount(context);
    if (!mounted || !ok) return;
    await controller.refresh(local, force: local);
    final profile = controller.services.accounts;
    if (local && (profile?.isCloud != true || profile!.useLocalCredentials)) {
      unawaited(controller.services.monitor.start());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final entries = controller.accounts(_local);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (controller.services.accounts?.isCloud == true &&
                !widget.localOnly) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: controller.acting
                      ? null
                      : () async {
                          final next = !_local;
                          if (await controller.run(
                                () => controller.switchSource(next),
                              ) &&
                              mounted) {
                            setState(() => _local = next);
                          }
                        },
                  icon: const Icon(Icons.swap_horiz),
                  label: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _local
                          ? '本机账号 · 点击切换至 Zipliner 绑定账号'
                          : 'Zipliner 绑定账号 · 点击切换至本机账号',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Card(
              color: colors.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: .5),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _local ? '本机游戏账号' : '已绑定的游戏账号',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${_local ? '已保存' : '已绑定'} ${entries.length} 个账号',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: controller.loading
                              ? null
                              : () => controller.refresh(_local, force: true),
                          tooltip: '刷新账号',
                          icon: const Icon(Icons.refresh),
                        ),
                        IconButton.filledTonal(
                          onPressed: controller.acting ? null : _add,
                          tooltip: _local ? '添加本机账号' : '绑定游戏账号',
                          icon: const Icon(Icons.link),
                        ),
                      ],
                    ),
                    if (controller.loading)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                    if (controller.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          controller.error!,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (!controller.loading && entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _local ? '还没有本机账号，点击右上角添加。' : '还没有绑定游戏账号，点击右上角绑定。',
                        ),
                      ),
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: GameAccountRow(
                          account: entry,
                          current: entry.roles.any(controller.isCurrent),
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (_) => GameAccountDialog(
                              controller: controller,
                              accountId: entry.id,
                              local: _local,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
