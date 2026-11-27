import 'package:zipliner_client/features/accounts/application/client_accounts.dart';
import 'package:zipliner_client/features/accounts/storage/local_guest_store.dart';

import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tf_framework/tf_framework.dart';

import 'package:zipliner_client/features/overlay/desktop_overlay.dart';
import 'package:zipliner_client/platform/desktop/game_window_locator.dart';
import 'package:zipliner_client/features/weak_network/weak_network_controller.dart';
import 'package:zipliner_client/features/weak_network/region_position_link.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/features/maps/application/map_names.dart';
import 'package:zipliner_client/app/app_preferences.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/integrations/skland/position_socket.dart';
import 'package:zipliner_client/integrations/skland/skland_client.dart';
import 'package:zipliner_client/shared/http/api_client.dart';
import 'package:zipliner_client/app/config.dart';
import 'package:zipliner_client/features/settings/application/update_checker.dart';
import 'package:zipliner_client/shared/http/cookie_storage.dart';

/// 应用级依赖的组合根。页面通过 `AppScope.of(context)` 取用。
///
/// - [client]：Zipliner 后端，提供区域名称与高度范围。
/// - [skland] / [tokens] / [monitor]：本机直连森空岛的坐标同步。
/// - [overlay]：桌面端坐标悬浮窗，移动端为 null。
/// - [dataDirectory]：日志所在的文件夹。
class AppServices {
  AppServices({
    required this.client,
    required this.skland,
    required this.tokens,
    required this.monitor,
    required this.updates,
    required this.dataDirectory,
    this.overlay,
    this.accounts,
    WeakNetworkController? weakNetwork,
    TfPreferencesController? preferences,
  }) : weakNetwork =
           weakNetwork ??
           WeakNetworkController(
             dataDirectory: dataDirectory,
             preferences: preferences,
           ) {
    overlay?.attachWeakNetwork(this.weakNetwork);
    mapNames = MapNames(client);
    _regionPositionLink = RegionPositionLink(client, monitor, this.weakNetwork);
    accounts?.beforeIdentityChange = () async {
      await this.weakNetwork.setEnabled(false);
      await monitor.disconnect();
      monitor.sessions.clear();
      monitor.selectedRoleKey = null;
    };
    if (preferences != null) {
      this.weakNetwork.initialize();
    }
  }

  late final RegionPositionLink _regionPositionLink;
  late final MapNames mapNames;

  /// 生产装配：Cookie 与 token 都存到系统安全存储。
  factory AppServices.create(
    TfPreferencesController prefs, {
    required String dataDirectory,
    String? Function()? languageProvider,
  }) {
    final skland = SklandClient(
      languageProvider: () =>
          languageProvider?.call()?.split('-').first ?? 'zh',
    );
    final api = ApiClient(
      baseUrl: AppConfig.apiBaseUrl,
      cookieJar: PersistCookieJar(storage: SecureCookieStorage()),
      languageProvider: languageProvider,
      metadataPreferences: prefs,
    );
    final guest = LocalGuestStore(
      legacySelectedRole: prefs.get(AppPreferences.selectedRole),
    );
    final tokens = TokenRepository(guest);
    final accounts = ClientAccounts(api, prefs, guest, tokens);
    final gameWindow = GameWindowLocator(
      targetExecutable: () => prefs.get(AppPreferences.gameExecutable),
    );
    api.onUnauthorized = (_) => accounts.sessionExpired();
    final monitor = _monitor(
      prefs,
      skland,
      tokens,
      accounts: accounts,
      gameWindowPresent: gameWindow.isSupported
          ? gameWindow.hasGameWindow
          : null,
      gameWindowName: () => gameWindow.targetName,
    );
    return AppServices(
      preferences: prefs,
      client: api,
      accounts: accounts,
      skland: skland,
      tokens: tokens,
      monitor: monitor,
      updates: UpdateChecker(),
      dataDirectory: dataDirectory,
      overlay: DesktopOverlay.isSupported
          ? (DesktopOverlay(prefs, locator: gameWindow)..attachMonitor(monitor))
          : null,
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
    final sklandDio = Dio(
      BaseOptions(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    if (sklandAdapter != null) sklandDio.httpClientAdapter = sklandAdapter;
    final skland = SklandClient(dio: sklandDio);
    final repository = TokenRepository(MemoryTokenStore(tokens));
    final dataDirectory = Directory.systemTemp.path;
    return AppServices(
      preferences: prefs,
      client: ApiClient(
        baseUrl: baseUrl,
        cookieJar: CookieJar(),
        httpClientAdapter: httpClientAdapter,
      ),
      skland: skland,
      tokens: repository,
      monitor: _monitor(
        prefs,
        skland,
        repository,
        socketFactory: socketFactory,
      ),
      updates: UpdateChecker(currentVersion: 'dev'),
      dataDirectory: dataDirectory,
    );
  }

  static PositionMonitor _monitor(
    TfPreferencesController prefs,
    SklandClient skland,
    TokenRepository tokens, {
    PositionSocket Function()? socketFactory,
    ClientAccounts? accounts,
    bool Function()? gameWindowPresent,
    String Function()? gameWindowName,
  }) {
    final selected = prefs.get(AppPreferences.selectedRole);
    return PositionMonitor(
        client: skland,
        tokens: tokens,
        accounts: accounts,
        gameWindowPresent: gameWindowPresent,
        gameWindowName: gameWindowName,
        socketFactory: socketFactory,
        selectedRoleKey: selected.isEmpty ? null : selected,
      )
      ..onRoleSelected = (key) {
        if (accounts == null) prefs.set(AppPreferences.selectedRole, key);
      };
  }

  /// 桌面端使用“文档/Zipliner”，Android 使用应用私有目录。
  static Future<String> defaultDataDirectory() async {
    final base = Platform.isAndroid
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}Zipliner');
    try {
      dir.createSync(recursive: true);
    } catch (_) {
      // 目录创建失败时，日志功能自行降级。
    }
    return dir.path;
  }

  final ClientAccounts? accounts;
  final ApiClient client;
  final SklandClient skland;
  final TokenRepository tokens;
  final PositionMonitor monitor;
  final UpdateChecker updates;
  final String dataDirectory;
  final DesktopOverlay? overlay;
  final WeakNetworkController weakNetwork;

  void dispose() {
    accounts?.dispose();
    _regionPositionLink.dispose();
    mapNames.dispose();
    monitor.dispose();
    weakNetwork.dispose();
    overlay?.dispose();
    updates.dispose();
  }
}
