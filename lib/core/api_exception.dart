/// 一次 API 调用失败：网络错误、非 2xx 状态，或信封里 `success:false`。
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.code, this.data, this.requestId});

  /// 服务端给出的可读消息（已本地化），没有时为通用描述。
  final String message;

  /// HTTP 状态码；网络层失败时为 null。
  final int? statusCode;

  /// 业务错误码，例如 `request.invalid`、`ACCOUNT_CHANGED`、`CsrfTokenInvalid`。
  final String? code;

  final Object? data;
  final String? requestId;

  bool get isNetworkError => statusCode == null;
  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isConflict => statusCode == 409;

  @override
  String toString() => statusCode == null ? message : '$message ($statusCode${code == null ? '' : ' $code'})';
}
