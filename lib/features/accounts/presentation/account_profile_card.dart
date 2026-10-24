import 'package:zipliner_client/app/app_scope.dart';
import 'package:flutter/material.dart';

import 'package:zipliner_client/features/accounts/presentation/account_manager_page.dart';

class AccountProfileCard extends StatelessWidget {
  const AccountProfileCard({super.key});
  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final accounts = services.accounts;
    if (accounts == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([accounts, services.monitor]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(accounts.title),
                subtitle: Text(accounts.credentialSourceLabel),
                trailing: TextButton(
                  onPressed: () =>
                      accounts.chooseMode(logout: accounts.isCloud),
                  child: Text(accounts.isCloud ? '退出登录' : '登录 Zipliner'),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AccountManagerPage()),
              ),
              child: const Text('账号管理'),
            ),
          ),
        ],
      ),
    );
  }
}
