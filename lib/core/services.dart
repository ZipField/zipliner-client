import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tf_framework/tf_framework.dart';

import '../api/system_api.dart';
import '../desktop/desktop_overlay.dart';
import '../position/position_monitor.dart';
import '../position/position_prefs.dart';
import '../position/token_store.dart';
import '../skland/position_socket.dart';
import '../skland/skland_client.dart';
import 'api_client.dart';
import 'config.dart';
import 'update_checker.dart';
import 'cookie_storage.dart';

/// 应用级依赖的组合根。页面通过 [AppServices.of] 取用。
///
/// - [client] / [system]：Zipliner 后端（坐标功能不使用）。
/// - [skland] / [tokens] / [monitor]：本机直连森空岛的坐标同步与滑索采集。
/// - [overlay]：桌面端坐标悬浮窗，移动端为 null。
/// - [dataDirectory]：采集 CSV 与日志所在的文件夹。
class AppServices {
  AppServices({
    required this.client,
    required this.skland,
    required this.tokens,
    required this.monitor,
    required this.updates,
    required this.dataDirectory,
    this.overlay,
  }) : system = SystemApi(client);

  /// 生产装配：Cookie 与 token 都存到系统安全存储。
  factory AppServices.create(
    TfPreferencesController prefs, {
    required String dataDirectory,
    String? Function()? languageProvider,
  }) {
    final skland = SklandClient(languageProvider: () => languageProvider?.call()?.split('-').first ?? 'zh');
    final tokens = TokenRepository(SecureTokenStore());
    return AppServices(
      client: ApiClient(
        baseUrl: AppConfig.apiBaseUrl,
        cookieJar: PersistCookieJar(storage: SecureCookieStorage()),
        languageProvider: languageProvider,
      ),
      skland: skland,
      tokens: tokens,
      monitor: _monitor(prefs, skland, tokens, dataDirectory: dataDirectory),
      updates: UpdateChecker(),
      dataDirectory: dataDirectory,
      overlay: DesktopOverlay.isSupported ? DesktopOverlay(prefs) : null,
    );
  }

  /// 测试装配：全部使用内存实现，可注入假的 HTTP 适配器与 WebSocket。
  factory AppServices.inMemory(
    TfPreferencesController prefs, {
    HttpClientAdapter? httpClientAdapter,
    HttpClientAdapter? sklandAdapter,
    PositionSocket Function()? socketFactory,
    List<StoredToken> tokens = const [],
    String baseUrl = 'https://api.test',
  }) {
    final sklandDio = Dio(BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true));
    if (sklandAdapter != null) sklandDio.httpClientAdapter = sklandAdapter;
    final skland = SklandClient(dio: sklandDio);
    final repository = TokenRepository(MemoryTokenStore(tokens));
    final dataDirectory = Directory.systemTemp.path;
    return AppServices(
      client: ApiClient(baseUrl: baseUrl, cookieJar: CookieJar(), httpClientAdapter: httpClientAdapter),
      skland: skland,
      tokens: repository,
      monitor: _monitor(prefs, skland, repository, socketFactory: socketFactory, dataDirectory: dataDirectory),
      updates: UpdateChecker(currentVersion: 'dev'),
      dataDirectory: dataDirectory,
    );
  }

  static PositionMonitor _monitor(
    TfPreferencesController prefs,
    SklandClient skland,
    TokenRepository tokens, {
    required String dataDirectory,
    PositionSocket Function()? socketFactory,
  }) {
    final selected = prefs.get(PositionPrefs.selectedRole);
    return PositionMonitor(
      client: skland,
      tokens: tokens,
      socketFactory: socketFactory,
      captureDirectory: () async => dataDirectory,
      selectedRoleKey: selected.isEmpty ? null : selected,
      recordCapture: prefs.get(PositionPrefs.recordCapture),
    )..onRoleSelected = (key) => prefs.set(PositionPrefs.selectedRole, key);
  }

  /// 桌面端为“文档/Zipliner”，便于用户找到采集文件；Android 为应用私有目录。
  static Future<String> defaultDataDirectory() async {
    final base = Platform.isAndroid ? await getApplicationSupportDirectory() : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}Zipliner');
    try {
      dir.createSync(recursive: true);
    } catch (_) {
      // 目录创建失败时，采集与日志功能自行降级。
    }
    return dir.path;
  }

  final ApiClient client;
  final SystemApi system;
  final SklandClient skland;
  final TokenRepository tokens;
  final PositionMonitor monitor;
  final UpdateChecker updates;
  final String dataDirectory;
  final DesktopOverlay? overlay;

  void dispose() {
    monitor.dispose();
    overlay?.dispose();
    updates.dispose();
  }

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载');
    return scope!.services;
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
