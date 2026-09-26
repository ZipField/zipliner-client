import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../skland/skland_models.dart';

class StoredToken {
  const StoredToken({required this.id, required this.token, required this.region, this.addedAt, this.label});

  factory StoredToken.fromJson(Map<String, dynamic> json) => StoredToken(
    id: json['id']?.toString() ?? '',
    token: json['token']?.toString() ?? '',
    region: SklandRegion.parse(json['region']?.toString()),
    addedAt: DateTime.tryParse(json['addedAt']?.toString() ?? ''),
    label: json['label']?.toString(),
  );

  final String id;
  final String token;
  final SklandRegion region;
  final DateTime? addedAt;

  /// 上次成功加载时的角色名，账号登录失效后仍能认出是哪个账号。
  final String? label;

  StoredToken copyWith({String? token, SklandRegion? region, String? label}) => StoredToken(
    id: id,
    token: token ?? this.token,
    region: region ?? this.region,
    addedAt: addedAt,
    label: label ?? this.label,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'token': token,
    'region': region.name,
    'addedAt': addedAt?.toUtc().toIso8601String(),
    'label': ?label,
  };
}

/// 鹰角通行证登录 token 列表。原工具明文写在 `token.txt`，这里改存系统安全存储
/// （Windows DPAPI、Linux libsecret、Android Keystore）。
abstract interface class TokenStore {
  Future<List<StoredToken>> load();

  Future<void> save(List<StoredToken> tokens);
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'zipliner.skland.tokens';

  final FlutterSecureStorage _storage;

  @override
  Future<List<StoredToken>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (item is Map) StoredToken.fromJson(item.cast<String, dynamic>()),
      ].where((t) => t.token.trim().isNotEmpty).toList();
    } on FormatException {
      return [];
    }
  }

  @override
  Future<void> save(List<StoredToken> tokens) =>
      _storage.write(key: _key, value: jsonEncode([for (final t in tokens) t.toJson()]));
}

class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([List<StoredToken>? initial]) : _tokens = [...?initial];

  List<StoredToken> _tokens;

  @override
  Future<List<StoredToken>> load() async => [..._tokens];

  @override
  Future<void> save(List<StoredToken> tokens) async => _tokens = [...tokens];
}

/// 对 [TokenStore] 的增删封装；同一 token 重复添加时不会产生重复项。
class TokenRepository {
  TokenRepository(this._store);

  final TokenStore _store;

  Future<List<StoredToken>> list() => _store.load();

  Future<StoredToken> add(String token, SklandRegion region) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) throw const SklandException('token 为空');
    final tokens = await _store.load();
    for (final existing in tokens) {
      if (existing.token == trimmed) return existing;
    }
    final stored = StoredToken(id: _newId(), token: trimmed, region: region, addedAt: DateTime.now());
    await _store.save([...tokens, stored]);
    return stored;
  }

  Future<void> remove(String id) async {
    final tokens = await _store.load();
    await _store.save(tokens.where((t) => t.id != id).toList());
  }

  /// 重新登录后替换失效的 token，保留账号在列表中的位置。
  Future<void> replace(String id, String token, SklandRegion region) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) throw const SklandException('token 为空');
    final tokens = await _store.load();
    await _store.save([
      for (final t in tokens)
        if (t.id == id) t.copyWith(token: trimmed, region: region) else if (t.token != trimmed) t,
    ]);
  }

  Future<void> setLabel(String id, String label) async {
    final tokens = await _store.load();
    if (!tokens.any((t) => t.id == id && t.label != label)) return;
    await _store.save([for (final t in tokens) t.id == id ? t.copyWith(label: label) : t]);
  }

  static String _newId() {
    final random = Random.secure();
    return List.generate(12, (_) => random.nextInt(16).toRadixString(16)).join();
  }
}
