import 'package:zipliner_client/app/app_scope.dart';
import 'package:zipliner_client/features/position/presentation/position_account_actions.dart';
import 'package:zipliner_client/features/accounts/presentation/local_account_actions.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/position/models/friendly_error.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/shared/widgets/section_body.dart';

import 'package:zipliner_client/features/position/presentation/position_ui_actions.dart';
import 'package:zipliner_client/features/position/presentation/coordinate_readout.dart';

class PositionStatusSection extends StatelessWidget {
  const PositionStatusSection({super.key, required this.monitor});

  final PositionMonitor monitor;

  Future<void> _chooseRole(BuildContext context) async {
    final key = await showTfActionSheet<String>(
      context,
      title: '切换角色',
      actions: [
        for (final role in monitor.roles)
          TfSheetAction(
            label: '${role.displayName}（服务器 ${role.binding.serverId}）',
            value: role.key,
            icon: role.key == monitor.activeRole?.key
                ? Icons.check
                : Icons.person_outline,
          ),
      ],
    );
    if (key != null) unawaited(monitor.switchRole(key));
  }

  Future<void> _agreePolicy(BuildContext context) async {
    final ok = await showTfConfirm(
      context,
      title: '同意位置同步政策',
      message:
          '森空岛地图的“位置同步”需要角色同意相关政策后才会下发坐标。确认后将以当前角色调用森空岛的同意接口，'
          '效果等同于在森空岛地图工具中打开“位置同步”。',
      confirmLabel: '同意并连接',
    );
    if (ok) unawaited(monitor.agreePolicyAndConnect());
  }

  Future<void> _fix(BuildContext context, FixAction action) async {
    switch (action) {
      case FixAction.login:
        await addPositionAccount(context);
      case FixAction.relogin:
        final failed = monitor.failedAccounts.keys.toSet();
        final accounts = await AppScope.of(context).tokens.list();
        final target = accounts.where((a) => failed.contains(a.id)).toList();
        if (!context.mounted) return;
        // 只有一个失效账号时直接打开重新登录，多个时让用户在账号管理里选择。
        target.length == 1
            ? await reloginAccount(context, target.single)
            : openPositionAccounts(context);
      case FixAction.agreePolicy:
        await _agreePolicy(context);
      case FixAction.reconnect:
        await monitor.start();
    }
  }

  static String _fixLabel(FixAction action) => switch (action) {
    FixAction.login => '登录',
    FixAction.relogin => '重新登录',
    FixAction.agreePolicy => '同意并连接',
    FixAction.reconnect => '重新连接',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final role = monitor.activeRole;
    final position = monitor.position;
    final problem = monitor.problem;
    final retryIn = monitor.retryInSeconds;
    final (icon, color) = monitor.isError
        ? (Icons.error_outline, scheme.error)
        : monitor.isConnected || position != null
        ? (Icons.check_circle, Colors.green)
        : (Icons.radio_button_unchecked, scheme.onSurfaceVariant);

    final title =
        problem?.title ?? (monitor.status.isEmpty ? '正在连接...' : monitor.status);
    final subtitle = [
      if (retryIn != null) '$retryIn 秒后自动重连',
      ?monitor.warning,
    ].join('\n');

    return TfSection(
      title: '状态',
      children: [
        TfListTile(
          leading: monitor.isConnecting
              ? const TfProgress.circular()
              : Icon(icon, color: color),
          title: Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(title),
              if (monitor.syncedToWebsite)
                Text(
                  '已同步至 Zipliner 网页端',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          trailing: TfButton.text(
            label: '重新连接',
            onPressed: monitor.isConnecting ? null : monitor.start,
          ),
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  subtitle,
                  style: TextStyle(
                    color: monitor.warning != null ? scheme.error : null,
                  ),
                ),
        ),
        if (problem?.hint != null)
          SectionBody(
            child: TfBanner(
              type: problem!.retryable ? TfToastType.info : TfToastType.warning,
              message: problem.hint!,
            ),
          ),
        CoordinateReadout(monitor: monitor),
        TfListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('角色'),
          subtitle: Text(
            role == null
                ? '未选择'
                : '${role.displayName} · 服务器 ${role.binding.serverId}',
          ),
          trailing: monitor.roles.length > 1
              ? const Icon(Icons.chevron_right)
              : null,
          onTap: monitor.roles.length > 1 && !monitor.isConnecting
              ? () => _chooseRole(context)
              : null,
        ),
        TfListTile(
          leading: const Icon(Icons.map_outlined),
          title: const Text('地图'),
          subtitle: Text(
            AppScope.of(context).mapNames.label(monitor.mapId, monitor.levelId),
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (!monitor.hasTokens ||
            (problem?.action != null && problem!.action != FixAction.reconnect))
          SectionBody(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!monitor.hasTokens)
                  TfButton(
                    label: '登录',
                    icon: Icons.login,
                    onPressed: () => addPositionAccount(context),
                  )
                else if (problem?.action != null &&
                    problem!.action != FixAction.reconnect)
                  TfButton(
                    label: _fixLabel(problem.action!),
                    onPressed: () => _fix(context, problem.action!),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
