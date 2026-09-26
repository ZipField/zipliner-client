/// 编译期配置。可在构建时覆盖：
///
/// ```
/// flutter run --dart-define=ZIPLINER_API_BASE_URL=http://localhost:52802
/// ```
abstract final class AppConfig {
  /// Zipliner API 根地址，不含结尾斜杠。
  static final String apiBaseUrl = normalizeBaseUrl(
    const String.fromEnvironment('ZIPLINER_API_BASE_URL', defaultValue: 'https://api.zipliner.org'),
  );

  /// 后端对带会话 Cookie 的 POST 要求 Origin 在 `Cors:AllowedOrigins` 白名单内，
  /// 原生客户端没有浏览器来源，只能声明为官方站点。
  static final String webOrigin = normalizeBaseUrl(
    const String.fromEnvironment('ZIPLINER_WEB_ORIGIN', defaultValue: 'https://zipliner.org'),
  );

  /// 单个请求的超时时间。
  static const requestTimeout = Duration(seconds: 20);

  /// 去掉结尾斜杠，避免拼出 `//api/...`。
  static String normalizeBaseUrl(String url) => url.trim().replaceFirst(RegExp(r'/+$'), '');
}
