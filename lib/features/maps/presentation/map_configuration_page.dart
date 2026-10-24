import 'package:zipliner_client/app/app_scope.dart';
import 'package:flutter/material.dart';

import 'package:zipliner_client/shared/http/api_exception.dart';

class MapConfigurationPage extends StatefulWidget {
  const MapConfigurationPage({super.key});
  @override
  State<MapConfigurationPage> createState() => _MapConfigurationPageState();
}

class _MapConfigurationPageState extends State<MapConfigurationPage> {
  bool _loading = false;
  bool _started = false;
  String? _error;
  List<Map<String, dynamic>> _maps = [];
  final _regions = <String, List<Map<String, dynamic>>>{};
  final _errors = <String, String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    final api = AppScope.of(context).client;
    setState(() {
      _loading = true;
      _error = null;
      _errors.clear();
      _regions.clear();
    });
    try {
      dynamic data = await api.getMapMetadata('/api/maps/info');
      if (data is Map && data['maps'] is! List) data = data['data'];
      if (data is! Map || data['maps'] is! List) {
        throw const FormatException('地图列表格式无效');
      }
      final maps = [
        for (final m in data['maps'] as List)
          if (m is Map && m['id'] is String) m.cast<String, dynamic>(),
      ];
      if (!mounted) return;
      setState(() => _maps = maps);
      await Future.wait(
        maps.map((m) async {
          final id = m['id'] as String;
          try {
            final config = await api.getMapMetadata(
              '/api/maps/region-config',
              query: {'mapId': id},
            );
            if (config is! Map ||
                config['mapId'] != id ||
                config['regions'] is! List) {
              throw const FormatException('高度配置格式无效');
            }
            if (!mounted) return;
            setState(
              () => _regions[id] = [
                for (final r in config['regions'] as List)
                  if (r is Map) r.cast<String, dynamic>(),
              ],
            );
          } catch (e) {
            if (mounted) {
              setState(
                () => _errors[id] = e is ApiException
                    ? e.message
                    : '未能读取高度配置，请刷新重试。',
              );
            }
          }
        }),
      );
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '未能读取地图列表，请刷新重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _height(Object? value) => value == null ? '无' : value.toString();

  @override
  Widget build(BuildContext context) {
    final monitor = AppScope.of(context).monitor;
    return Scaffold(
      appBar: AppBar(
        title: const Text('地图名称与高度配置'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            '低于限低或高于限高为限制区；未设置的限低或限高显示“无”。两项均为“无”表示没有高度限制。网络不可用时使用已有本机缓存。',
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (final map in _maps)
            Card(
              child: ExpansionTile(
                initiallyExpanded: map['id'] == monitor.mapId,
                title: Text((map['name'] ?? map['id']).toString()),
                subtitle: Text(map['id'] as String),
                children: [
                  if (_errors[map['id']] != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _errors[map['id']]!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_regions[map['id']] case final regions?) ...[
                    if (regions.isEmpty &&
                        (map['levels'] as List? ?? const []).isEmpty)
                      const ListTile(title: Text('暂无区域配置')),
                    for (final level in (map['levels'] as List? ?? const []))
                      if (level is Map && level['id'] is String)
                        _regionRow(map, level, regions),
                    for (final region in regions)
                      if (!(map['levels'] as List? ?? const []).any(
                        (l) => l is Map && l['id'] == region['levelId'],
                      ))
                        _regionRow(map, {
                          'id': region['levelId'],
                          'name': region['name'],
                        }, regions),
                  ] else if (_errors[map['id']] == null)
                    const ListTile(title: Text('正在读取高度配置…')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _regionRow(Map map, Map level, List<Map<String, dynamic>> regions) {
    final id = level['id']?.toString() ?? '';
    final range = regions.where((r) => r['levelId'] == id).firstOrNull;
    final name = (level['name'] ?? range?['name'] ?? id).toString();
    // A missing region entry is unknown; only an existing entry with null
    // bounds means the service has explicitly supplied no height limits.
    final textStyle = Theme.of(context).textTheme.bodyLarge
        ?.copyWith(fontSize: 18);
    final limits = Text(
      range == null
          ? '暂无配置'
          : '限低：${_height(range['yLow'])}    限高：${_height(range['yHigh'])}',
      style: textStyle,
    );
    return LayoutBuilder(
      builder: (context, constraints) => ListTile(
        title: Text('${map['name'] ?? map['id']} / $name'),
        subtitle: constraints.maxWidth < 650
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(id), const SizedBox(height: 8), limits],
              )
            : Text(id),
        trailing: constraints.maxWidth < 650 ? null : limits,
      ),
    );
  }
}
