import 'package:zipliner_client/app/app_scope.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zipliner_client/features/accounts/presentation/account_manager_page.dart';

import 'package:zipliner_client/features/accounts/presentation/local_account_actions.dart';

Future<bool> addPositionAccount(BuildContext context) async {
  if (AppScope.of(context).accounts?.isCloud == true) {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AccountManagerPage()));
    return true;
  }
  return addAccount(context);
}
