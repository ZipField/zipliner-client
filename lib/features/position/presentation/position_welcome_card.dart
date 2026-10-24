import 'package:zipliner_client/features/position/presentation/position_account_actions.dart';
import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/settings/presentation/help_page.dart';

class PositionWelcomeCard extends StatelessWidget {
  const PositionWelcomeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget step(int n, String title, String detail) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            '$n',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              Text(detail, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
    return TfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text('欢迎使用Zipliner Client', style: theme.textTheme.titleMedium),
          step(1, '登录森空岛账号', '推荐用森空岛 App 扫码，国际服选 SKPort。'),
          step(2, '打开位置同步', '工具会检测并提示你一键开启，也可以在森空岛地图工具右下角打开。'),
          step(3, '进入游戏', '登录对应角色后坐标会自动显示，断线会自动重连。'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TfButton(
                label: '登录森空岛账号',
                icon: Icons.login,
                onPressed: () => addPositionAccount(context),
              ),
              TfButton.text(
                label: '使用帮助',
                icon: Icons.help_outline,
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const HelpPage())),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
