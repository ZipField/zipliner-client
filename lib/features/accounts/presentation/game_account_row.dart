import 'package:flutter/material.dart';
import 'package:zipliner_client/features/accounts/application/game_accounts_controller.dart';

import 'package:zipliner_client/features/accounts/presentation/account_badge.dart';

class GameAccountRow extends StatelessWidget {
  const GameAccountRow({
    super.key,
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
                const AccountBadge(
                  icon: Icons.sports_esports_outlined,
                  label: '当前角色',
                ),
              if (account.isDefault)
                const AccountBadge(icon: Icons.star_outline, label: '默认账号'),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
