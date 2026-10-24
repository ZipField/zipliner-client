import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zipliner_client/features/accounts/presentation/local_account_actions.dart';
import 'package:zipliner_client/features/accounts/presentation/bound_account_actions.dart';
import 'package:zipliner_client/features/accounts/application/game_accounts_controller.dart';

import 'package:zipliner_client/features/accounts/presentation/account_badge.dart';

class GameAccountDialog extends StatefulWidget {
  const GameAccountDialog({
    super.key,
    required this.controller,
    required this.accountId,
    required this.local,
  });
  final GameAccountsController controller;
  final String accountId;
  final bool local;
  @override
  State<GameAccountDialog> createState() => _GameAccountDialogState();
}

class _GameAccountDialogState extends State<GameAccountDialog> {
  String? _selected;

  Future<void> _remove(ManagedGameAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.local ? '移除本机账号' : '解除游戏账号绑定'),
        content: Text(
          widget.local
              ? '确定移除“${account.name}”？不会删除 Zipliner 网站上的绑定。'
              : '确定解除“${account.name}”的绑定？网站上的绑定也会被移除，本机凭据不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (await widget.controller.run(
          () => widget.controller.remove(account.id, widget.local),
        ) &&
        mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _relogin(ManagedGameAccount account) async {
    final controller = widget.controller;
    final ok = widget.local
        ? await reloginAccount(
            context,
            account.localToken!,
            repository: controller.services.tokens,
            reconnect: false,
            expectedRoles: account.roles,
          )
        : await bindCloudAccount(
            context,
            accountId: account.id,
            region: account.region,
          );
    if (!mounted || !ok) return;
    controller.services.monitor.sessions.invalidateAccount(account.id, cloud: !widget.local);
    if (!widget.local) {
      await controller.services.accounts!.forgetDirectCredential(account.id);
    }
    await controller.refresh(widget.local, force: widget.local);
    final active = controller.services.monitor.activeRole;
    if (active?.tokenId == account.id &&
        (active?.gameAccountId == null) == widget.local) {
      unawaited(controller.services.monitor.start());
    }
  }

  Future<void> _rename(ManagedGameAccount account) async {
    final input = TextEditingController(text: account.name);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改账号名称'),
        content: TextField(controller: input, maxLength: 80),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    input.dispose();
    if (value == null || value.isEmpty || !mounted) return;
    await widget.controller.run(() async {
      await widget.controller.services.accounts!.api.post(
        '/api/account/game-accounts/label',
        auth: true,
        body: {'gameAccountId': account.id, 'label': value},
      );
      await widget.controller.refresh(false);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final account = controller
          .accounts(widget.local)
          .where((a) => a.id == widget.accountId)
          .firstOrNull;
      if (account == null) {
        return AlertDialog(
          title: const Text('账号已移除'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      }
      final roles = account.roles;
      final selected =
          roles.where((r) => r.key == _selected).firstOrNull ??
          roles.where(controller.isCurrent).firstOrNull ??
          roles
              .where((r) => controller.isDefaultRole(r, widget.local))
              .firstOrNull ??
          roles.firstOrNull;
      final colors = Theme.of(context).colorScheme;
      return AlertDialog(
        scrollable: true,
        title: Row(
          children: [
            const Icon(Icons.person_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(account.name)),
            if (!widget.local)
              IconButton(
                onPressed: controller.acting ? null : () => _rename(account),
                tooltip: '修改名称',
                icon: const Icon(Icons.edit_outlined),
              ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              tooltip: '关闭',
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${account.region.label} · ${widget.local ? '本机保存' : 'Zipliner 绑定'}',
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '默认游戏账号',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 4),
                        Text('未选择当前角色时，优先使用此账号。'),
                      ],
                    ),
                  ),
                  if (account.isDefault)
                    const AccountBadge(icon: Icons.check, label: '默认账号')
                  else
                    TextButton(
                      onPressed: controller.acting
                          ? null
                          : () => controller.run(
                              () => controller.setDefaultAccount(
                                account.id,
                                widget.local,
                              ),
                            ),
                      child: const Text('设为默认'),
                    ),
                ],
              ),
              const Divider(height: 32),
              Text('游戏角色', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              if (roles.isEmpty && account.error == null)
                const Text('尚未找到游戏角色，请先在森空岛 / SKPort 中绑定。'),
              for (final role in roles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: selected?.key == role.key
                        ? colors.secondaryContainer
                        : colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: controller.acting
                          ? null
                          : () => setState(() => _selected = role.key),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    role.displayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '服务器 ${role.binding.serverId} · UID ${role.binding.roleId}',
                                  ),
                                ],
                              ),
                            ),
                            if (controller.isCurrent(role))
                              const AccountBadge(
                                icon: Icons.sports_esports_outlined,
                                label: '当前角色',
                              ),
                            if (controller.isDefaultRole(role, widget.local))
                              const AccountBadge(
                                icon: Icons.star_outline,
                                label: '默认角色',
                              ),
                            if (selected?.key == role.key)
                              const Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: Icon(Icons.check_circle_outline),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (account.error != null)
                Text(account.error!, style: TextStyle(color: colors.error)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: controller.acting ? null : () => _relogin(account),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新登录游戏账号'),
                ),
              ),
              if (controller.error != null)
                Text(controller.error!, style: TextStyle(color: colors.error)),
              if (controller.acting) const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: controller.acting ? null : () => _remove(account),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            icon: const Icon(Icons.delete_outline),
            label: Text(widget.local ? '移除本机账号' : '解除绑定'),
          ),
          if (selected != null &&
              !controller.isDefaultRole(selected, widget.local))
            TextButton(
              onPressed: controller.acting
                  ? null
                  : () => controller.run(
                      () => controller.setDefaultRole(selected, widget.local),
                    ),
              child: const Text('设为该账号默认角色'),
            ),
          if (selected != null && !controller.isCurrent(selected))
            FilledButton.icon(
              onPressed: controller.acting
                  ? null
                  : () async {
                      if (await controller.run(
                            () => controller.useRole(selected, widget.local),
                          ) &&
                          context.mounted) {
                        Navigator.pop(context);
                      }
                    },
              icon: const Icon(Icons.sports_esports_outlined),
              label: const Text('使用此角色'),
            ),
        ],
      );
    },
  );
}
