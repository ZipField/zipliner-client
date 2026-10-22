import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_exception.dart';
import '../core/services.dart';
import '../position/token_store.dart';
import '../skland/skland_models.dart';

class ManagedGameAccount {
  const ManagedGameAccount({
    required this.id,
    required this.name,
    required this.region,
    required this.roles,
    required this.isDefault,
    this.error,
    this.localToken,
  });
  final String id;
  final String name;
  final SklandRegion region;
  final List<RoleSession> roles;
  final bool isDefault;
  final String? error;
  final StoredToken? localToken;
}

/// The same account panel works with backend bindings and the local guest store.
/// Reading or managing accounts never depends on the position connection state.
class GameAccountsController extends ChangeNotifier {
  GameAccountsController(this.services) {
    services.accounts?.addListener(_changed);
    services.monitor.addListener(_changed);
  }
  final AppServices services;
  List<StoredToken> _tokens = [];
  final _localRoles = <String, List<RoleSession>>{};
  final _localErrors = <String, String>{};
  final _defaults = <String, String?>{};
  String? _defaultAccount;
  bool loading = false;
  bool acting = false;
  String? error;
  bool _disposed = false;
  int _revision = 0;

  List<ManagedGameAccount> accounts(bool local) {
    final profile = services.accounts;
    if (!local && profile?.isCloud == true) {
      return [
        for (final a in profile!.gameAccounts)
          ManagedGameAccount(
            id: a.id,
            name: a.label,
            region: a.region,
            isDefault: a.isDefault,
            roles: [
              for (final r in profile.gameRoles.where(
                (r) => r.accountId == a.id,
              ))
                r.session(a.region),
            ],
          ),
      ];
    }
    return [
      for (final token in _tokens)
        ManagedGameAccount(
          id: token.id,
          name: _rolesFor(token.id).isNotEmpty
              ? _rolesFor(token.id).map((r) => r.displayName).join('、')
              : token.label?.isNotEmpty == true
              ? token.label!
              : token.region.label,
          region: token.region,
          localToken: token,
          isDefault: token.id == _defaultAccount,
          error: _localErrors[token.id],
          roles: _rolesFor(token.id),
        ),
    ];
  }

  List<RoleSession> _rolesFor(String id) {
    final live = services.monitor.roles
        .where((r) => r.tokenId == id && r.hasLocalCredential)
        .toList();
    return live.isNotEmpty ? live : _localRoles[id] ?? const [];
  }

  bool isCurrent(RoleSession role) {
    final active = services.monitor.activeRole;
    return active != null &&
        active.hasLocalCredential == role.hasLocalCredential &&
        active.tokenId == role.tokenId &&
        active.region == role.region &&
        active.binding.serverId == role.binding.serverId &&
        active.binding.roleId == role.binding.roleId;
  }

  bool isDefaultRole(RoleSession role, bool local) => local
      ? _defaults[role.tokenId] == role.key
      : services.accounts!.gameRoles.any(
          (r) => r.key == role.key && r.isDefault,
        );

  Future<void> refresh(bool local, {bool force = false}) async {
    final revision = ++_revision;
    loading = true;
    error = null;
    _changed();
    try {
      if (!local && services.accounts?.isCloud == true) {
        await services.accounts!.refreshBindings();
      } else {
        final tokens = await services.tokens.list();
        final guest = services.accounts?.guest;
        final defaultAccount = await guest?.defaultAccount();
        if (_disposed || revision != _revision) return;
        _tokens = tokens;
        _defaultAccount = defaultAccount ?? tokens.firstOrNull?.id;
        await Future.wait(
          tokens.map((token) async {
            final defaultRole = await guest?.defaultRoleFor(token.id);
            final existing = _rolesFor(token.id);
            List<RoleSession> roles = existing;
            String? failure;
            if (roles.isEmpty || force) {
              try {
                final credential = await services.skland.login(
                  token.token,
                  token.region,
                );
                final bindings = await services.skland.getRoleBindings(
                  credential,
                  token.region,
                );
                roles = [
                  for (final b in bindings)
                    RoleSession(
                      tokenId: token.id,
                      region: token.region,
                      credential: credential,
                      binding: b,
                    ),
                ];
              } catch (e) {
                failure = e is SklandException ? e.message : '暂时无法读取角色，请重试。';
              }
            }
            if (_disposed || revision != _revision) return;
            _defaults[token.id] = defaultRole ?? roles.firstOrNull?.key;
            _localRoles[token.id] = roles;
            if (failure == null) {
              _localErrors.remove(token.id);
            } else {
              _localErrors[token.id] = failure;
            }
            _changed();
          }),
        );
      }
    } catch (e) {
      if (!_disposed && revision == _revision) error = _message(e);
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        _changed();
      }
    }
  }

  Future<bool> run(Future<void> Function() action) async {
    if (acting) return false;
    acting = true;
    error = null;
    _changed();
    try {
      await action();
      return true;
    } catch (e) {
      error = _message(e);
      return false;
    } finally {
      acting = false;
      _changed();
    }
  }

  Future<void> useRole(RoleSession role, bool local) async {
    final profile = services.accounts;
    if (profile?.isCloud == true) {
      await profile!.useLocalAccounts(local);
    } else {
      await profile?.beforeIdentityChange?.call();
    }
    // start() owns the long-running socket. Do not keep the account dialog busy
    // for the entire connection lifetime.
    await profile?.selectRole(role.key);
    services.monitor.selectedRoleKey = role.key;
    if (profile == null) services.monitor.onRoleSelected?.call(role.key);
    unawaited(services.monitor.start());
  }

  Future<void> switchSource(bool local) async {
    final previous = services.monitor.activeRole;
    final profile = services.accounts;
    if (profile?.isCloud != true) return;
    await profile!.useLocalAccounts(local);
    await refresh(local);
    final available = accounts(local).expand((a) => a.roles);
    final matching = available
        .where(
          (r) =>
              r.region == previous?.region &&
              r.binding.serverId == previous?.binding.serverId &&
              r.binding.roleId == previous?.binding.roleId,
        )
        .firstOrNull;
    if (matching != null) {
      await profile.selectRole(matching.key);
      services.monitor.selectedRoleKey = matching.key;
    }
    unawaited(services.monitor.start());
  }

  Future<void> setDefaultRole(RoleSession role, bool local) async {
    if (local) {
      await services.accounts?.guest.setRole(role.key, asDefault: true);
    } else {
      await services.accounts!.setDefaultRole(role);
    }
    await refresh(local);
  }

  Future<void> setDefaultAccount(String id, bool local) async {
    if (local) {
      await services.accounts?.guest.setDefaultAccount(id);
    } else {
      await services.accounts!.setDefaultAccount(id);
    }
    await refresh(local);
  }

  Future<void> remove(String id, bool local) async {
    if (local) {
      final activeHere =
          services.monitor.activeRole?.tokenId == id &&
          services.monitor.activeRole?.hasLocalCredential == true;
      if (activeHere) {
        await services.weakNetwork.setEnabled(false);
        await services.monitor.disconnect();
      }
      await services.tokens.remove(id);
      _localRoles.remove(id);
      if (activeHere) unawaited(services.monitor.start());
    } else {
      await services.accounts!.unlink(id);
      unawaited(services.monitor.start());
    }
    await refresh(local);
  }

  String _message(Object e) => e is ApiException
      ? e.message
      : e is SklandException
      ? e.message
      : '账号操作未完成，请重试。';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    services.accounts?.removeListener(_changed);
    services.monitor.removeListener(_changed);
    super.dispose();
  }
}
