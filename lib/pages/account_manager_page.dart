import 'package:flutter/material.dart';

import '../account/game_accounts_panel.dart';

class AccountManagerPage extends StatelessWidget {
  const AccountManagerPage({super.key, this.localOnly = false});
  final bool localOnly;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('账号管理')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: GameAccountsPanel(localOnly: localOnly),
        ),
      ),
    ),
  );
}
