import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import 'api_exception.dart';
import 'config.dart';

typedef Json = Map<String, dynamic>;

/// 访问 Zipliner API 的唯一 HTTP 入口。
///
/// 服务端契约（见 Zipliner.Server `AccountPostGuardMiddleware`）：
/// - 会话只通过 `Set-Cookie` 下发，所以请求必须经过持久化的 Cookie jar；
/// - 带会话 Cookie 的 POST 必须带白名单内的 `Origin`；
/// - `/api/account/*` 下受保护的 POST 需要 `X-Zipliner-CSRF`；
/// - 响应统一为 `{success, data, message, code?, requestId?}`。
class ApiClient {
  ApiClient({
    required String baseUrl,
    required this.cookieJar,
    String? origin,
    HttpClientAdapter? httpClientAdapter,
    this.languageProvider,
    Duration timeout = AppConfig.requestTimeout,
  }) : baseUrl = AppConfig.normalizeBaseUrl(baseUrl),
       origin = origin ?? AppConfig.webOrigin,
       _dio = Dio(
         BaseOptions(
           baseUrl: AppConfig.normalizeBaseUrl(baseUrl),
           connectTimeout: timeout,
           receiveTimeout: timeout,
           sendTimeout: timeout,
           responseType: ResponseType.plain,
           validateStatus: (_) => true,
         ),
       ) {
    if (httpClientAdapter != null) _dio.httpClientAdapter = httpClientAdapter;
    _dio.interceptors.add(CookieManager(cookieJar));
  }

  static const sessionCookieNames = ['__Host-zipliner_session', 'zipliner_session'];
  static const csrfHeader = 'X-Zipliner-CSRF';

  /// 这些 `/api/account/*` 路由在服务端被列为 CSRF 豁免，调用时不能先去拿令牌
  /// （例如登录前根本没有会话）。
  static const _csrfExemptPrefixes = [
    '/api/account/register',
    '/api/account/login/password',
    '/api/account/email/verify',
    '/api/account/email/verification/resend',
    '/api/account/password/reset/',
    '/api/account/migration/skland/qr/create',
    '/api/account/migration/skport/email-password',
    '/api/account/migration/claim',
  ];

  final String baseUrl;
  final String origin;
  final CookieJar cookieJar;
  final Dio _dio;

  /// 返回当前界面语言（如 `zh-CN`），作为 `X-Language` 发送。
  String? Function()? languageProvider;

  /// 需要登录的请求返回 401 时调用，用于把界面切回登录页。
  void Function(ApiException error)? onUnauthorized;

  String? _csrfToken;
  DateTime? _csrfExpiresAt;
  Future<String>? _csrfInFlight;

  Uri get _baseUri => Uri.parse(baseUrl);

  Future<dynamic> get(String path, {Map<String, Object?>? query, bool auth = false}) =>
      _send('GET', path, query: query, auth: auth);

  Future<dynamic> post(String path, {Object? body, Map<String, Object?>? query, bool auth = false}) =>
      _send('POST', path, body: body, query: query, auth: auth);

  /// 下载二进制内容（例如二维码图片）。
  Future<Uint8List> getBytes(String path, {Map<String, Object?>? query}) async {
    final Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        path,
        queryParameters: _compactQuery(query),
        options: Options(responseType: ResponseType.bytes, headers: _baseHeaders()),
      );
    } on DioException catch (e) {
      throw ApiException(_networkMessage(e));
    }
    final status = response.statusCode ?? 0;
    final bytes = Uint8List.fromList(response.data ?? const []);
    if (status < 200 || status >= 300) {
      final text = utf8.decode(bytes, allowMalformed: true);
      throw _errorFrom(status, _tryDecode(text), text);
    }
    return bytes;
  }

  /// 当前会话令牌（来自 Cookie jar）；SignalR 在原生端拿不到 Dio 的 Cookie，
  /// 用 `X-Zipliner-Session` 头传递它。
  Future<String?> sessionToken() async {
    final cookies = await cookieJar.loadForRequest(_baseUri);
    for (final name in sessionCookieNames) {
      for (final cookie in cookies) {
        if (cookie.name == name && cookie.value.isNotEmpty) return cookie.value;
      }
    }
    return null;
  }

  Future<bool> hasSession() async => await sessionToken() != null;

  /// 退出或会话失效后清掉本地 Cookie 与 CSRF。
  Future<void> clearSession() async {
    resetCsrf();
    await cookieJar.deleteAll();
  }

  void resetCsrf() {
    _csrfToken = null;
    _csrfExpiresAt = null;
    _csrfInFlight = null;
  }

  Future<String> _ensureCsrf() {
    final token = _csrfToken;
    final expiresAt = _csrfExpiresAt;
    if (token != null && expiresAt != null && DateTime.now().isBefore(expiresAt)) return Future.value(token);
    return _csrfInFlight ??= _fetchCsrf().whenComplete(() => _csrfInFlight = null);
  }

  Future<String> _fetchCsrf() async {
    final data = await _send('GET', '/api/account/csrf', auth: true);
    final json = data is Map ? data : const {};
    final token = json['csrfToken']?.toString() ?? '';
    if (token.isEmpty) throw const ApiException('服务器没有返回 CSRF 令牌');
    final seconds = (json['expiresInSeconds'] as num?)?.toInt() ?? 1800;
    _csrfToken = token;
    // 提前一分钟刷新，避免请求在途中过期。
    _csrfExpiresAt = DateTime.now().add(Duration(seconds: seconds > 120 ? seconds - 60 : seconds));
    return token;
  }

  bool _needsCsrf(String path) => path.startsWith('/api/account/') && !_csrfExemptPrefixes.any(path.startsWith);

  Map<String, Object> _baseHeaders() {
    final language = languageProvider?.call();
    return {if (language != null && language.isNotEmpty) 'X-Language': language};
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? query,
    bool auth = false,
    bool retried = false,
  }) async {
    final isPost = method == 'POST';
    final headers = _baseHeaders();
    if (isPost) {
      headers['Origin'] = origin;
      if (_needsCsrf(path) && await hasSession()) headers[csrfHeader] = await _ensureCsrf();
    }

    final Response<String> response;
    try {
      response = await _dio.request<String>(
        path,
        data: body,
        queryParameters: _compactQuery(query),
        options: Options(method: method, headers: headers, contentType: isPost ? Headers.jsonContentType : null),
      );
    } on DioException catch (e) {
      if (!isPost && !retried && _isTransient(e)) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return _send(method, path, query: query, auth: auth, retried: true);
      }
      throw ApiException(_networkMessage(e));
    }

    final status = response.statusCode ?? 0;
    final text = response.data ?? '';
    final decoded = _tryDecode(text);

    if (status >= 200 && status < 300) {
      if (decoded is Map && decoded.containsKey('success')) {
        if (decoded['success'] == false) throw _errorFrom(status, decoded, text);
        return decoded['data'];
      }
      return decoded ?? (text.isEmpty ? null : text);
    }

    if (isPost && status == 403 && !retried && text.contains('CSRF token')) {
      resetCsrf();
      return _send(method, path, body: body, query: query, auth: auth, retried: true);
    }
    if (!isPost && !retried && const {502, 503, 504}.contains(status)) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return _send(method, path, query: query, auth: auth, retried: true);
    }

    final error = _errorFrom(status, decoded, text);
    if (status == 401 && auth) {
      resetCsrf();
      onUnauthorized?.call(error);
    }
    throw error;
  }

  static Map<String, Object?>? _compactQuery(Map<String, Object?>? query) {
    if (query == null) return null;
    final result = <String, Object?>{};
    query.forEach((key, value) {
      if (value == null) return;
      if (value is String && value.isEmpty) return;
      result[key] = value is DateTime ? value.toUtc().toIso8601String() : value;
    });
    return result;
  }

  static Object? _tryDecode(String text) {
    if (text.isEmpty) return null;
    final first = text.trimLeft();
    if (!first.startsWith('{') && !first.startsWith('[')) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static ApiException _errorFrom(int status, Object? decoded, String text) {
    String? message;
    String? code;
    String? requestId;
    Object? data;
    if (decoded is Map) {
      data = decoded['data'];
      message = _firstString([decoded['message'], decoded['error_description'], decoded['error'], decoded['title']]);
      code = _firstString([decoded['code'], decoded['errorCode']]);
      if (code == null && data is Map) code = _firstString([data['code'], data['errorCode']]);
      requestId = decoded['requestId']?.toString();
    } else if (text.isNotEmpty && text.length < 300) {
      message = text.trim();
    }
    code ??= _codeFromMessage(message);
    if (code == null && status == 409) code = 'Conflict';
    return ApiException(
      message ?? _statusMessage(status),
      statusCode: status,
      code: code,
      data: data,
      requestId: requestId,
    );
  }

  static const _knownCodes = [
    'TokenMissing',
    'TokenExpired',
    'SessionInvalid',
    'Forbidden',
    'CsrfTokenRequired',
    'CsrfTokenInvalid',
    'PreferencesConflict',
    'WikiConflict',
    'SnapshotRequired',
  ];

  static String? _codeFromMessage(String? message) {
    if (message == null) return null;
    for (final code in _knownCodes) {
      if (message.contains(code)) return code;
    }
    if (message == 'CSRF token required') return 'CsrfTokenRequired';
    if (message == 'CSRF token invalid') return 'CsrfTokenInvalid';
    return null;
  }

  static String? _firstString(List<Object?> values) {
    for (final value in values) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static String _statusMessage(int status) => switch (status) {
    400 => '请求参数有误',
    401 => '未登录或登录已过期',
    403 => '没有权限执行此操作',
    404 => '请求的内容不存在',
    409 => '数据已被修改，请刷新后重试',
    423 => '账号尚未完成邮箱验证',
    429 => '请求过于频繁，请稍后再试',
    >= 500 => '服务器暂时不可用，请稍后再试',
    _ => '请求失败（$status）',
  };

  static bool _isTransient(DioException e) => switch (e.type) {
    DioExceptionType.connectionError || DioExceptionType.connectionTimeout || DioExceptionType.receiveTimeout => true,
    _ => false,
  };

  static String _networkMessage(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => '连接服务器超时，请检查网络',
    DioExceptionType.badCertificate => '服务器证书无效',
    DioExceptionType.cancel => '请求已取消',
    _ => '无法连接到服务器，请检查网络',
  };
}
