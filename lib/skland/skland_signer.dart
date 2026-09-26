import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 森空岛请求签名，与后端 `SklandService.CreateSign` 一致：
/// `md5(hex(hmacSha256(token, path + queryOrBody + timestamp + headerJson)))`。
abstract final class SklandSigner {
  static String headerJson(String timestamp) => '{"platform":"3","timestamp":"$timestamp","dId":"","vName":"1.0.0"}';

  static String sign({
    required String path,
    required String queryOrBody,
    required String timestamp,
    required String token,
  }) {
    final source = path + queryOrBody + timestamp + headerJson(timestamp);
    final hmacHex = Hmac(sha256, utf8.encode(token)).convert(utf8.encode(source)).toString();
    return md5.convert(utf8.encode(hmacHex)).toString();
  }

  /// 服务端要求时间戳略早于当前时间；[offset] 为本机与网络时间的差值。
  static String timestamp(DateTime nowUtc, {Duration offset = Duration.zero}) =>
      (nowUtc.add(offset).subtract(const Duration(seconds: 3)).millisecondsSinceEpoch ~/ 1000).toString();
}
