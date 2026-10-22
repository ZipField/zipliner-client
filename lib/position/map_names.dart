import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/app_log.dart';

class MapNames extends ChangeNotifier {
  MapNames(this.client);

  final ApiClient client;
  final _maps = <String, String>{};
  final _levels = <String, String>{};
  final _parents = <String, String>{};
  bool _loading = false;
  bool _loaded = false;
  bool _disposed = false;
  DateTime? _retryAfter;

  Future<void> load() async {
    if (_disposed ||
        _loading ||
        _loaded ||
        (_retryAfter?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    _loading = true;
    try {
      dynamic data = await client.getMapMetadata('/api/maps/info');
      // ApiClient unwraps success/data; this endpoint has an additional
      // code/message/data envelope around its maps collection.
      if (data is Map && data['maps'] is! List) data = data['data'];
      if (data is! Map || data['maps'] is! List) {
        throw const FormatException('地图名称格式无效');
      }
      if (_disposed) return;
      for (final item in data['maps'] as List) {
        if (item is! Map || item['id'] is! String) continue;
        final id = item['id'] as String;
        final name = item['name'];
        if (name is String && name.trim().isNotEmpty) _maps[id] = name.trim();
        final levels = item['levels'];
        if (levels is! List) continue;
        for (final level in levels) {
          if (level is! Map || level['id'] is! String) continue;
          final levelId = level['id'] as String;
          _parents[levelId] = id;
          final levelName = level['name'];
          if (levelName is String && levelName.trim().isNotEmpty) {
            _levels[levelId] = levelName.trim();
          }
        }
      }
      _loaded = true;
      notifyListeners();
    } catch (error) {
      if (!_disposed) {
        _retryAfter = DateTime.now().add(const Duration(seconds: 30));
        AppLog.instance.warn('地图名称读取失败：$error');
      }
    } finally {
      _loading = false;
    }
  }

  String label(String? mapId, String? levelId) {
    var map = mapId?.trim();
    var level = levelId?.trim();
    if ((level == null || level.isEmpty) && map?.contains('_lv') == true) {
      level = map;
      map = null;
    }
    if (level != null && level.isNotEmpty && (map == null || map.isEmpty)) {
      map =
          _parents[level] ??
          RegExp(r'^(map\d+)_lv\d+').firstMatch(level)?.group(1);
    }
    final parts = [
      if (map != null && map.isNotEmpty) _maps[map] ?? map,
      if (level != null && level.isNotEmpty && level != map)
        _levels[level] ?? level,
    ];
    return parts.isEmpty ? '等待坐标同步' : parts.join(' / ');
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
