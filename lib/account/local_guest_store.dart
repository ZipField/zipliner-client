import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../position/token_store.dart';

/// A complete guest profile is committed in one secure-storage value. The old
/// token key is a read-only rollback copy and is never deleted by migration.
class LocalGuestStore implements TokenStore {
  LocalGuestStore({FlutterSecureStorage? storage, this.legacySelectedRole = ''})
    : _storage = storage ?? const FlutterSecureStorage();

  static const profileKey = 'zipliner.profiles.local-guest.v1';
  static const legacyKey = 'zipliner.skland.tokens';
  final FlutterSecureStorage _storage;
  final String legacySelectedRole;
  Future<void>? _initializing;
  Future<void> _writes = Future.value();
  bool migratedExistingUser = false;

  Future<void> initialize() =>
      _initializing ??= _migrate().catchError((Object e) {
        _initializing = null;
        throw e;
      });

  Map<String, dynamic> _decode(String raw) {
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data['schema'] != 1 ||
        data['id'] != 'local-guest' ||
        data['tokens'] is! List) {
      throw const FormatException('本地游客档案格式不正确，旧凭据未被删除。');
    }
    for (final item in data['tokens'] as List) {
      if (item is! Map ||
          item['id'] is! String ||
          item['token'] is! String ||
          (item['token'] as String).isEmpty) {
        throw const FormatException('本地游客凭据校验失败，旧凭据未被删除。');
      }
    }
    return data;
  }

  Future<void> _migrate() async {
    final existing = await _storage.read(key: profileKey);
    if (existing != null) {
      final profile = _decode(existing);
      migratedExistingUser = profile['migratedExistingUser'] == true;
      return;
    }
    final old = await _storage.read(key: legacyKey);
    final tokens = <StoredToken>[];
    if (old != null && old.isNotEmpty) {
      final values = jsonDecode(old);
      if (values is! List) {
        throw const FormatException('旧账号数据无法读取，迁移已停止，未覆盖凭据。');
      }
      for (final value in values) {
        if (value is! Map) throw const FormatException('旧账号数据校验失败，迁移已停止。');
        final token = StoredToken.fromJson(value.cast<String, dynamic>());
        // Matches the old store's definition of a usable credential.
        if (token.token.trim().isNotEmpty) tokens.add(token);
      }
    }
    final profile = <String, dynamic>{
      'schema': 1,
      'id': 'local-guest',
      'tokens': [for (final t in tokens) t.toJson()],
      'currentRole': legacySelectedRole,
      'defaultRole': legacySelectedRole,
      'migratedExistingUser': tokens.isNotEmpty,
    };
    final encoded = jsonEncode(profile);
    await _storage.write(key: profileKey, value: encoded);
    final verified = await _storage.read(key: profileKey);
    if (verified == null || jsonEncode(_decode(verified)) != encoded) {
      throw const FormatException('本地账号迁移写入未能确认，请重试；旧凭据仍保留。');
    }
    migratedExistingUser = tokens.isNotEmpty;
  }

  Future<Map<String, dynamic>> _read() async {
    final raw = await _storage.read(key: profileKey);
    if (raw == null) throw const FormatException('本地游客档案丢失，请勿清除应用数据。');
    return _decode(raw);
  }

  Future<void> _update(void Function(Map<String, dynamic>) change) {
    final operation = _writes.catchError((Object _) {}).then((_) async {
      await initialize();
      final data = await _read();
      change(data);
      final encoded = jsonEncode(data);
      await _storage.write(key: profileKey, value: encoded);
      if (await _storage.read(key: profileKey) != encoded) {
        throw const FormatException('本地档案保存未能确认，请重试。');
      }
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  @override
  Future<List<StoredToken>> load() async {
    await initialize();
    await _writes;
    final data = await _read();
    return [
      for (final v in data['tokens'] as List)
        StoredToken.fromJson((v as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<void> save(List<StoredToken> tokens) => _update((data) {
    data['tokens'] = [for (final t in tokens) t.toJson()];
    for (final field in ['currentRole', 'defaultRole']) {
      final key = data[field] as String? ?? '';
      if (key.isNotEmpty && !tokens.any((t) => key.startsWith('${t.id}:'))) {
        data[field] = '';
      }
    }
    final defaults = Map<String, dynamic>.from(
      data['defaultRoles'] as Map? ?? {},
    );
    defaults.removeWhere((id, _) => !tokens.any((t) => t.id == id));
    data['defaultRoles'] = defaults;
    if (!tokens.any((t) => t.id == data['defaultAccount'])) {
      data.remove('defaultAccount');
    }
  });

  Future<String?> role({bool defaultRole = false}) async {
    await initialize();
    await _writes;
    final data = await _read();
    String? value =
        data[defaultRole ? 'defaultRole' : 'currentRole'] as String?;
    if (defaultRole) {
      final account =
          data['defaultAccount'] as String? ??
          ((value?.contains(':') ?? false)
              ? value!.split(':').first
              : (data['tokens'] as List).firstOrNull?['id'] as String?);
      value = (data['defaultRoles'] as Map?)?[account] as String? ?? value;
    }
    return value == null || value.isEmpty ? null : value;
  }

  Future<String?> defaultAccount() async {
    await initialize();
    await _writes;
    final data = await _read();
    final explicit = data['defaultAccount'] as String?;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final legacy = data['defaultRole'] as String? ?? '';
    if (legacy.contains(':')) return legacy.split(':').first;
    return (data['tokens'] as List).firstOrNull?['id'] as String?;
  }

  Future<String?> defaultRoleFor(String accountId) async {
    await initialize();
    await _writes;
    final data = await _read();
    final value = (data['defaultRoles'] as Map?)?[accountId] as String?;
    if (value != null && value.isNotEmpty) return value;
    final legacy = data['defaultRole'] as String? ?? '';
    return legacy.startsWith('$accountId:') ? legacy : null;
  }

  Future<void> setDefaultAccount(String id) => _update((data) {
    if (!(data['tokens'] as List).any((t) => t['id'] == id)) {
      throw const FormatException('本机账号不存在');
    }
    final defaults = Map<String, dynamic>.from(
      data['defaultRoles'] as Map? ?? {},
    );
    final legacy = data['defaultRole'] as String? ?? '';
    if (legacy.contains(':')) {
      defaults.putIfAbsent(legacy.split(':').first, () => legacy);
    }
    data['defaultRoles'] = defaults;
    data['defaultAccount'] = id;
    data['defaultRole'] =
        (data['defaultRoles'] as Map?)?[id] ??
        ((data['defaultRole'] as String? ?? '').startsWith('$id:')
            ? data['defaultRole']
            : '');
  });

  Future<void> setRole(String key, {bool asDefault = false}) => _update((data) {
    if (!asDefault) {
      data['currentRole'] = key;
      return;
    }
    final id = key.split(':').first;
    final defaults = Map<String, dynamic>.from(
      data['defaultRoles'] as Map? ?? {},
    );
    final oldDefault = data['defaultRole'] as String? ?? '';
    if (oldDefault.contains(':')) {
      defaults.putIfAbsent(oldDefault.split(':').first, () => oldDefault);
    }
    defaults[id] = key;
    data['defaultRoles'] = defaults;
    data['defaultAccount'] ??= oldDefault.contains(':')
        ? oldDefault.split(':').first
        : ((data['tokens'] as List).firstOrNull?['id'] ?? id);
    if (data['defaultAccount'] == id) data['defaultRole'] = key;
  });
}
