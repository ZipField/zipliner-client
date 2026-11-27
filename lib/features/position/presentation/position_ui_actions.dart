import 'package:flutter/material.dart';
import 'package:zipliner_client/features/accounts/presentation/account_manager_page.dart';

void openPositionAccounts(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AccountManagerPage()));
