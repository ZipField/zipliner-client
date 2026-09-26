import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class FakeResponse {
  const FakeResponse(this.body, {this.status = 200, this.headers = const {}});

  factory FakeResponse.json(Object? body, {int status = 200, Map<String, List<String>> headers = const {}}) =>
      FakeResponse(
        jsonEncode(body),
        status: status,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
          ...headers,
        },
      );

  factory FakeResponse.text(String body, {int status = 200}) => FakeResponse(
    body,
    status: status,
    headers: {
      'content-type': ['text/plain; charset=utf-8'],
    },
  );

  final String body;
  final int status;
  final Map<String, List<String>> headers;
}

/// 记录请求并按脚本返回响应的 Dio 适配器。
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FakeResponse Function(RequestOptions request) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final response = handler(options);
    return ResponseBody.fromBytes(utf8.encode(response.body), response.status, headers: response.headers);
  }

  @override
  void close({bool force = false}) {}
}
