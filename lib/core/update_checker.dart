import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'app_info.dart';
import 'app_log.dart';

class UpdateInfo {
  const UpdateInfo({required this.version, required this.url, this.notes});

  final String version;
  final String url;
  final String? notes;
}

/// 查询 GitHub 上的最新 Release，有新版本时提示用户下载。
class UpdateChecker extends ChangeNotifier {
  UpdateChecker({Dio? dio, this.currentVersion = AppInfo.version})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              validateStatus: (_) => true,
            ),
          );

  final Dio _dio;
  final String currentVersion;

  UpdateInfo? available;
  bool checking = false;
  bool promptOpen = false;
  String? lastPromptedVersion;
  bool _disposed = false;
  Future<UpdateInfo?>? _pending;
  Timer? _initialCheck;
  Timer? _periodicCheck;

  /// 启动后检查，长时间运行时每 6 小时检查；开发构建不访问网络。
  void startAutomaticChecks() {
    if (_disposed || _parse(currentVersion) == null || _periodicCheck != null) return;
    _initialCheck = Timer(const Duration(seconds: 3), () => unawaited(check()));
    _periodicCheck = Timer.periodic(const Duration(hours: 6), (_) => unawaited(check()));
  }

  /// 上一次检查的结果描述，供设置页显示。
  String? lastResult;

  /// 返回可用的新版本；已是最新或检查失败返回 null。
  Future<UpdateInfo?> check() {
    if (_disposed) return Future.value(null);
    return _pending ??= _check().whenComplete(() => _pending = null);
  }

  Future<UpdateInfo?> _check() async {
    checking = true;
    notifyListeners();
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        AppInfo.latestReleaseApi,
        options: Options(headers: {'Accept': 'application/vnd.github+json'}),
      );
      final data = response.data;
      if (_disposed) return null;
      if (response.statusCode != 200 || data == null) {
        lastResult = response.statusCode == 404 ? '还没有发布版本' : '检查更新失败（${response.statusCode}）';
        return null;
      }
      final tag = data['tag_name']?.toString() ?? '';
      if (data['draft'] == true || data['prerelease'] == true || _parse(tag) == null) {
        lastResult = '没有可用的正式版本';
        available = null;
        return null;
      }
      final url = data['html_url']?.toString() ?? AppInfo.releasesPage;
      if (isNewer(tag, currentVersion)) {
        available = UpdateInfo(version: tag, url: url, notes: data['body']?.toString());
        lastResult = '发现新版本 $tag';
        AppLog.instance.info('发现新版本 $tag（当前 $currentVersion）');
      } else {
        available = null;
        lastResult = '已是最新版本（$currentVersion）';
      }
      return available;
    } catch (_) {
      lastResult = '检查更新失败，请检查网络';
      return null;
    } finally {
      checking = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 比较 `v1.2.3` 形式的版本号；当前版本不是正式版本号（如 `dev`）时不提示。
  static bool isNewer(String latest, String current) {
    final a = _parse(latest);
    final b = _parse(current);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static List<int>? _parse(String version) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+[0-9A-Za-z.-]+)?$').firstMatch(version.trim());
    if (match == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  @override
  void dispose() {
    _disposed = true;
    _initialCheck?.cancel();
    _periodicCheck?.cancel();
    _dio.close(force: true);
    super.dispose();
  }
}
