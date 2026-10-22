import 'dart:async';

import 'package:flutter/material.dart';

import '../core/services.dart';
import '../pages/login_page.dart';
import 'cloud_accounts_page.dart';
import 'game_accounts_controller.dart';

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
    final services = AppServices.of(context);
    _local =
        widget.localOnly ||
        services.accounts?.isCloud != true ||
        services.accounts!.forceDirect;
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
    if (local && (profile?.isCloud != true || profile!.forceDirect)) {
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
                        child: _AccountRow(
                          account: entry,
                          current: entry.roles.any(controller.isCurrent),
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (_) => _AccountDialog(
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

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.current,
    required this.onTap,
  });
  final ManagedGameAccount account;
  final bool current;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.secondaryContainer.withValues(alpha: .65),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.person_outline, size: 30),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${account.region.label} · ${account.roles.length} 个角色',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    if (account.error != null)
                      Text('登录状态需要检查', style: TextStyle(color: colors.error)),
                  ],
                ),
              ),
              if (current)
                const _Badge(
                  icon: Icons.sports_esports_outlined,
                  label: '当前角色',
                ),
              if (account.isDefault)
                const _Badge(icon: Icons.star_outline, label: '默认账号'),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(icon, size: 18, semanticLabel: label),
    ),
  );
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({
    required this.controller,
    required this.accountId,
    required this.local,
  });
  final GameAccountsController controller;
  final String accountId;
  final bool local;
  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
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
    await controller.refresh(widget.local, force: widget.local);
    if (widget.local &&
        controller.services.monitor.activeRole?.tokenId == account.id &&
        controller.services.monitor.activeRole?.hasLocalCredential == true) {
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
                    const _Badge(icon: Icons.check, label: '默认账号')
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
                              const _Badge(
                                icon: Icons.sports_esports_outlined,
                                label: '当前角色',
                              ),
                            if (controller.isDefaultRole(role, widget.local))
                              const _Badge(
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
