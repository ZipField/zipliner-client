import 'package:zipliner_client/features/accounts/application/client_accounts.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/integrations/skland/skland_client.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

/// Successful account setup belongs to this app session, not a socket attempt.
class DirectAccountSessions {
  DirectAccountSessions(this.client, this.accounts);
  final SklandClient client;
  final ClientAccounts? accounts;
  final _local = <String, Future<List<RoleSession>>>{};
  final _credentials = <String, Future<CredentialResult>>{};
  final _policies = <String, Future<bool>>{};
  final _socketTokens = <String, Future<String>>{};
  final _localVersions = <String, String>{};

  String _accountKey(RoleSession role) => role.gameAccountId == null
      ? 'local:${role.tokenId}'
      : '${accounts?.profileId ?? 'cloud'}:${role.tokenId}';
  String _roleKey(RoleSession role) => '${_accountKey(role)}:${role.key}';

  Future<T> _once<T>(
    Map<String, Future<T>> cache,
    String key,
    Future<T> Function() load,
  ) {
    final existing = cache[key];
    if (existing != null) return existing;
    late Future<T> pending;
    pending = Future<T>.sync(load).then(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        if (identical(cache[key], pending)) cache.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    cache[key] = pending;
    return pending;
  }

  Future<List<RoleSession>> local(StoredToken token) {
    final key = 'local:${token.id}';
    final version = '${token.region.name}:${token.token}';
    if (_localVersions[key] != version) {
      _local.remove(key);
      _policies.removeWhere((k, _) => k.startsWith('$key:'));
      _socketTokens.removeWhere((k, _) => k.startsWith('$key:'));
      _localVersions[key] = version;
    }
    return _once(_local, key, () async {
      final credential = await client.login(token.token, token.region);
      final bindings = await client.getRoleBindings(credential, token.region);
      return [
        for (final binding in bindings)
          RoleSession(
            tokenId: token.id,
            region: token.region,
            credential: credential,
            binding: binding,
          ),
      ];
    });
  }

  Future<RoleSession> cloud(RoleSession role) async {
    final profile = accounts!;
    final owner = profile.profileId;
    final credential = await _once(_credentials, _accountKey(role), () async {
      final token = await profile.directTokenFor(role);
      return client.login(token.token, token.region);
    });
    if (!profile.isCloud || profile.profileId != owner) {
      throw const SklandException('账号已切换，请重新连接。');
    }
    return RoleSession(
      tokenId: role.tokenId,
      region: role.region,
      credential: credential,
      binding: role.binding,
      gameAccountId: role.gameAccountId,
    );
  }

  Future<bool> policyAgreed(RoleSession role) => _once(
    _policies,
    _roleKey(role),
    () => client.hasAgreedPositionPolicy(
      role.credential,
      role.binding,
      role.region,
    ),
  );

  void markPolicyAgreed(RoleSession role) {
    _policies[_roleKey(role)] = Future.value(true);
  }

  /// Reuse the connection token until the official server rejects it with 10002.
  Future<String> socketToken(RoleSession role) => _once(
    _socketTokens,
    _roleKey(role),
    () => client.getWebSocketToken(role.credential, role.region),
  );

  void forgetSocketToken(RoleSession role) {
    _socketTokens.remove(_roleKey(role));
  }

  void invalidateAccount(String id, {required bool cloud}) {
    final key = cloud ? '${accounts?.profileId ?? 'cloud'}:$id' : 'local:$id';
    _local.remove(key);
    _credentials.remove(key);
    _policies.removeWhere((k, _) => k.startsWith('$key:'));
    _socketTokens.removeWhere((k, _) => k.startsWith('$key:'));
    _localVersions.remove(key);
  }

  void clear() {
    _local.clear();
    _credentials.clear();
    _policies.clear();
    _socketTokens.clear();
    _localVersions.clear();
  }
}
