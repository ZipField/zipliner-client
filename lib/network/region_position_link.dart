import 'dart:async';

import '../core/api_client.dart';
import '../core/app_log.dart';
import '../position/position_monitor.dart';
import 'weak_network_controller.dart';

/// Supplies fresh coordinate evidence without changing coordinate polling speed.
class RegionPositionLink {
  RegionPositionLink(this.client, this.monitor, this.network) {
    monitor.addListener(_onMonitor);
    network.addListener(_onNetwork);
    _onNetwork();
    _onMonitor();
  }

  final ApiClient client;
  final PositionMonitor monitor;
  final WeakNetworkController network;
  final _regions = <String, Map<String, _HeightRange>>{};
  final _loading = <String>{};
  final _retryAfter = <String, DateTime>{};
  bool _disposed = false;
  bool _prefetched = false;
  bool _enabled = false;
  bool _ready = false;
  String? _signature;

  void _onNetwork() {
    if (_disposed) return;
    final changed = _enabled != network.enabled || _ready != network.ready;
    _enabled = network.enabled;
    _ready = network.ready;
    if (_enabled && !_prefetched) {
      _prefetched = true;
      unawaited(_prefetch());
    }
    if (changed) _publish();
  }

  Future<void> _prefetch() async {
    try {
      dynamic data = await client.getMapMetadata('/api/maps/info');
      if (data is Map && data['maps'] is! List) data = data['data'];
      if (_disposed || data is! Map || data['maps'] is! List) return;
      for (final item in data['maps'] as List) {
        if (item is Map && item['id'] is String) {
          unawaited(_load(item['id'] as String));
        }
      }
    } catch (error) {
      if (!_disposed) AppLog.instance.warn('区域列表读取失败：$error');
    }
  }

  Future<void> _load(String map) async {
    if (_disposed ||
        _regions.containsKey(map) ||
        _loading.contains(map) ||
        (_retryAfter[map]?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    _loading.add(map);
    try {
      final data = await client.getMapMetadata(
        '/api/maps/region-config',
        query: {'mapId': map},
      );
      if (_disposed) return;
      if (data is! Map || data['mapId'] != map || data['regions'] is! List) {
        throw const FormatException('区域配置格式无效');
      }
      final regions = <String, _HeightRange>{};
      for (final value in data['regions'] as List) {
        if (value is Map && value['levelId'] is String) {
          regions[value['levelId'] as String] = _HeightRange.fromJson(value);
        }
      }
      _regions[map] = regions;
      _retryAfter.remove(map);
    } catch (error) {
      if (!_disposed) {
        _retryAfter[map] = DateTime.now().add(const Duration(seconds: 30));
        AppLog.instance.warn('区域高度范围读取失败：$error');
      }
    } finally {
      _loading.remove(map);
      if (!_disposed) _publish();
    }
  }

  void _onMonitor() {
    final signature =
        '${monitor.isConnected}/${monitor.positionRevision}/'
        '${monitor.activeRole?.key}/${monitor.mapId}/${monitor.levelId}';
    if (_disposed || signature == _signature) return;
    _signature = signature;
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    final position = monitor.position;
    final observedAt = monitor.positionReceivedAt;
    final role = monitor.activeRole?.key;
    final rawLevel = monitor.levelId?.trim();
    final rawMap = monitor.mapId?.trim();
    final level = rawLevel?.isNotEmpty == true ? rawLevel : rawMap;
    final derivedMap = level == null
        ? null
        : RegExp(r'^(map\d+)_lv\d+').firstMatch(level)?.group(1);
    final map = derivedMap ?? rawMap;
    if (!monitor.isConnected ||
        position == null ||
        observedAt == null ||
        role == null ||
        map == null ||
        map.isEmpty ||
        level == null ||
        level.isEmpty ||
        !position.x.isFinite ||
        !position.y.isFinite ||
        !position.z.isFinite) {
      network.updatePosition({'valid': false}, '请先连接坐标，以便自动确认离开区域。');
      return;
    }
    final range = _regions[map]?[level];
    if (range == null && network.enabled) unawaited(_load(map));
    final outside = range?.contains(position.y);
    network.updatePosition(
      {
        'valid': true,
        'observed_at_ms': observedAt.millisecondsSinceEpoch,
        'sequence': monitor.positionRevision,
        'role': role,
        'map': map,
        'level': level,
        'x': position.x,
        'y': position.y,
        'z': position.z,
        // outside means outside the restricted zone, i.e. within normal bounds.
        'outside': outside,
      },
      range == null
          ? '正在获取当前区域的高度范围；确认前会保留弱网。'
          : range.low == null && range.high == null
          ? '坐标已连接，当前区域没有高度限制。'
          : '坐标已连接，离开区域后将自动确认并恢复连接。',
    );
  }

  void dispose() {
    _disposed = true;
    monitor.removeListener(_onMonitor);
    network.removeListener(_onNetwork);
  }
}

class _HeightRange {
  const _HeightRange(this.low, this.high);
  factory _HeightRange.fromJson(Map value) {
    double? bound(String key) {
      final result = value[key];
      if (result == null) return null;
      if (result is! num || !result.toDouble().isFinite) {
        throw const FormatException('区域高度不是有效数字');
      }
      return result.toDouble();
    }

    final low = bound('yLow');
    final high = bound('yHigh');
    if (low != null && high != null && low > high) {
      throw const FormatException('区域高度范围无效');
    }
    return _HeightRange(low, high);
  }
  final double? low;
  final double? high;
  bool contains(double y) =>
      (low == null || y >= low!) && (high == null || y <= high!);
}
