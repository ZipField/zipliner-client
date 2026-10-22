import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tf_framework/tf_framework.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../position/token_store.dart';
import '../skland/skland_models.dart';
import 'account_models.dart';
import 'local_guest_store.dart';

enum ClientAccountMode { choose, guest, cloud }

class ClientAccounts extends ChangeNotifier {
  ClientAccounts(this.api, this.preferences, this.guest, this.localTokens);
  static const modePreference = TfPreferenceKey<String>(
    'account.mode',
    defaultValue: 'new',
  );
  static const _cachedIdentity = TfPreferenceKey<String>(
    'account.cachedIdentity',
    defaultValue: '',
  );
  final ApiClient api;
  final TfPreferencesController preferences;
  final LocalGuestStore guest;
  final TokenRepository localTokens;
  ClientAccountMode mode = ClientAccountMode.choose;
  ZiplinerIdentity? identity;
  List<CloudGameAccount> gameAccounts = [];
  List<CloudGameRole> gameRoles = [];
  bool initialized = false;
  bool busy = false;
  String? error;
  bool _disposed = false;

  Future<void> Function()? beforeIdentityChange;

  bool get isCloud => mode == ClientAccountMode.cloud;
  String get title => isCloud ? identity?.name ?? 'Zipliner 账号' : '本地游客';
  String get profileId => isCloud ? 'cloud:${identity!.id}' : 'local-guest';
  TfPreferenceKey<String> _key(String suffix) =>
      TfPreferenceKey<String>('account.$profileId.$suffix', defaultValue: '');
  bool get forceDirect => preferences.get(_key('source')) == 'direct';

  Future<void> _mergeLegacyDirectTokens(String owner) async {
    final marker = TfPreferenceKey<bool>(
      'account.$owner.directCredentialsMerged',
      defaultValue: false,
    );
    if (preferences.get(marker)) return;
    final old = await SecureTokenStore(
      key: 'zipliner.profiles.cloud.$owner.direct',
    ).load();
    final merged = [...await localTokens.list()];
    for (final token in old) {
      if (merged.any(
        (t) => t.token == token.token && t.region == token.region,
      )) {
        continue;
      }
      if (merged.any((t) => t.id == token.id)) {
        throw const FormatException('本机账号合并遇到重复标识，原凭据已保留。');
      }
      merged.add(token);
    }
    if (old.isNotEmpty) await guest.save(merged);
    await preferences.set(marker, true);
  }

  Future<void> initialize() async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      await guest.initialize();
      final saved = preferences.get(modePreference);
      if (saved == 'guest' || (saved == 'new' && guest.migratedExistingUser)) {
        mode = ClientAccountMode.guest;
        await preferences.set(modePreference, 'guest');
      } else if (saved == 'cloud') {
        final cached = preferences.get(_cachedIdentity);
        if (cached.isNotEmpty) {
          identity = ZiplinerIdentity(
            (jsonDecode(cached) as Map).cast<String, dynamic>(),
          );
        }
        if (identity != null) await _mergeLegacyDirectTokens(identity!.id);
        try {
          await _restoreCloud();
        } on ApiException catch (e) {
          if (e.isUnauthorized || e.isForbidden || identity == null) {
            identity = null;
            mode = ClientAccountMode.choose;
            error = 'Zipliner 登录已失效，请重新登录，或选择本地模式。';
          } else {
            mode = ClientAccountMode.cloud;
            _loadRoleCache();
            error = 'Zipliner 暂时无法连接，可以在账号面板中使用本机账号。';
          }
        }
      }
      if (saved == 'new' && mode == ClientAccountMode.choose) {
        await preferences.set(modePreference, 'choose');
      }
      initialized = true;
    } catch (_) {
      error = '本地账号初始化或迁移未完成。旧凭据已保留，请点击重试；不要清除应用数据。';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _restoreCloud() async {
    final data = await api.get('/api/account/session', auth: true);
    identity = ZiplinerIdentity((data as Map).cast<String, dynamic>());
    await _mergeLegacyDirectTokens(identity!.id);
    mode = ClientAccountMode.cloud;
    await preferences.set(_cachedIdentity, jsonEncode(identity!.data));
    await refreshBindings();
  }

  Future<void> login(String identifier, String password) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      await beforeIdentityChange?.call();
      await api.post(
        '/api/account/login/password',
        body: {
          identifier.contains('@') ? 'email' : 'account': identifier.trim(),
          'password': password,
        },
      );
      api.resetCsrf();
      await _restoreCloud();
      await preferences.set(modePreference, 'cloud');
    } catch (e) {
      mode = ClientAccountMode.choose;
      error = e is ApiException ? e.message : '登录未完成，请检查网络后重试。';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> enterGuest() async {
    if (busy || !initialized) return;
    busy = true;
    _notify();
    try {
      await beforeIdentityChange?.call();
      await preferences.set(modePreference, 'guest');
      mode = ClientAccountMode.guest;
      error = null;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> chooseMode({bool logout = false}) async {
    if (busy) return;
    busy = true;
    _notify();
    try {
      await beforeIdentityChange?.call();
      if (logout) {
        try {
          await api.post('/api/account/logout', auth: true);
        } catch (_) {
          /* Always clear this device's local session. */
        } finally {
          await api.clearSession();
          await preferences.set(_cachedIdentity, '');
          identity = null;
        }
      }
      mode = ClientAccountMode.choose;
      await preferences.set(modePreference, 'choose');
      error = null;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> refreshBindings() async {
    final owner = identity?.id;
    final lists = await Future.wait([
      api.get('/api/account/game-accounts', auth: true),
      api.get('/api/account/game-accounts/roles', auth: true),
    ]);
    if (owner != identity?.id || !isCloud) return;
    gameAccounts = [
      for (final a in lists[0] as List)
        CloudGameAccount((a as Map).cast<String, dynamic>()),
    ];
    final ids = gameAccounts.map((a) => a.id).toSet();
    gameRoles = [
      for (final r in lists[1] as List)
        if (ids.contains((r as Map)['gameAccountId']))
          CloudGameRole(r.cast<String, dynamic>()),
    ];
    await preferences.set(
      _key('bindings'),
      jsonEncode({
        'accounts': [for (final a in gameAccounts) a.data],
        'roles': [for (final r in gameRoles) r.data],
      }),
    );
    _notify();
  }

  void _loadRoleCache() {
    final raw = preferences.get(_key('bindings'));
    if (raw.isEmpty) return;
    final data = jsonDecode(raw) as Map;
    gameAccounts = [
      for (final a in data['accounts'] as List)
        CloudGameAccount((a as Map).cast<String, dynamic>()),
    ];
    gameRoles = [
      for (final r in data['roles'] as List)
        CloudGameRole((r as Map).cast<String, dynamic>()),
    ];
  }

  Future<String?> selectedRole() async {
    if (!isCloud || forceDirect) {
      return await guest.role() ?? await guest.role(defaultRole: true);
    }
    final key = preferences.get(_key('currentRole'));
    if (gameRoles.any((r) => r.key == key)) return key;
    final account = gameAccounts.where((a) => a.isDefault).firstOrNull;
    final preferred = gameRoles
        .where((r) => r.isDefault && r.accountId == account?.id)
        .firstOrNull;
    if (preferred != null) return preferred.key;
    return gameRoles.where((r) => r.isDefault).firstOrNull?.key;
  }

  Future<void> selectRole(String key) async {
    if (isCloud && !forceDirect) {
      await preferences.set(_key('currentRole'), key);
    } else {
      await guest.setRole(key);
    }
    _notify();
  }

  Future<void> setDefaultRole(RoleSession role) async {
    if (isCloud) {
      await api.post(
        '/api/account/game-accounts/roles/set-default',
        auth: true,
        body: {
          'gameAccountId': role.gameAccountId,
          'roleId': role.binding.roleId,
          'serverId': role.binding.serverId,
        },
      );
      await refreshBindings();
    } else {
      await guest.setRole(role.key, asDefault: true);
      _notify();
    }
  }

  Future<void> setDefaultAccount(String id) async {
    if (!isCloud) {
      await guest.setDefaultAccount(id);
      _notify();
      return;
    }
    await api.post(
      '/api/account/game-accounts/set-default',
      body: {'gameAccountId': id},
      auth: true,
    );
    await refreshBindings();
  }

  Future<void> unlink(String id) async {
    await beforeIdentityChange?.call();
    await api.post(
      '/api/account/game-accounts/unlink',
      body: {'gameAccountId': id},
      auth: true,
    );
    await refreshBindings();
  }

  Future<void> useLocalAccounts(bool value) async {
    await beforeIdentityChange?.call();
    await preferences.set(_key('source'), value ? 'direct' : 'cloud');
    _notify();
  }

  List<RoleSession> cloudSessions() => [
    for (final r in gameRoles)
      r.session(gameAccounts.firstWhere((a) => a.id == r.accountId).region),
  ];

  void sessionExpired() {
    if (!isCloud || busy || _disposed) return;
    mode = ClientAccountMode.choose;
    error = 'Zipliner 登录已失效，请重新登录，或使用本地模式。';
    unawaited(preferences.set(modePreference, 'choose'));
    unawaited(beforeIdentityChange?.call());
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
