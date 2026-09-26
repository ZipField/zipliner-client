import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'skland_models.dart';
import 'skland_signer.dart';

/// 直接在本机访问森空岛 / SKPort 接口，逻辑照抄后端 `Zipliner.Server/Services/SklandService.cs`，
/// 不经过 Zipliner 服务器。
class SklandClient {
  SklandClient({Dio? dio, this.languageProvider})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 20),
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            ),
          );

  static const _sklandAppCode = '4ca99fa6b56cc2ba';
  static const _skportAppCode = '6eb76d4e13aa36e6';
  static const _grantPath = '/user/oauth2/v2/grant';
  static const _generateCredentialPath = '/api/v1/user/auth/generate_cred_by_code';
  static const _genScanPath = '/general/v1/gen_scan/login';
  static const _scanStatusPath = '/general/v1/scan_status';
  static const _tokenByScanPath = '/user/auth/v1/token_by_scan_code';
  static const _tokenByPhonePasswordPath = '/user/auth/v1/token_by_phone_password';
  static const _tokenByEmailPasswordPath = '/user/auth/v1/token_by_email_password';
  static const _sendPhoneCodePath = '/general/v1/send_phone_code';
  static const _tokenByPhoneCodePath = '/user/auth/v2/token_by_phone_code';
  static const _bindingPath = '/api/v1/game/player/binding';
  static const _webSocketTokenPath = '/api/v1/websocket/token';
  static const _mapMePath = '/web/v1/game/endfield/map/me';
  static const _agreePolicyPath = '/web/v1/game/endfield/map/agree-policy';
  static const _markListPath = '/web/v1/game/endfield/map/mark/list';
  static const ziplineTemplateIds = {'0f45150a59b97bd0de9a4eed7a0fbf23', '5d53bdb714ba42c1e1a1b748b55b686f'};

  final Dio _dio;

  /// 返回 `zh` / `en` 等语言代码，SKPort 请求会据此发送 `sk-language`。
  String Function()? languageProvider;

  /// 本机时间与网络时间的差值，用于签名时间戳；时钟偏差过大时签名会被拒绝。
  Duration networkTimeOffset = Duration.zero;

  static String asUrl(SklandRegion region, String path) =>
      (region.isSkport ? 'https://as.gryphline.com' : 'https://as.hypergryph.com') + path;

  static String zonaiUrl(SklandRegion region, String path) =>
      (region.isSkport ? 'https://zonai.skport.com' : 'https://zonai.skland.com') + path;

  static String wsUrl(SklandRegion region) => region.isSkport ? 'wss://ws.skport.com' : 'wss://ws.skland.com';

  static String? skLanguage(SklandRegion region, String? language) {
    if (!region.isSkport) return null;
    return switch (language) {
      'en' => 'en',
      'ja' => 'ja',
      'ko' => 'ko',
      _ => 'zh_Hans',
    };
  }

  // ---- 登录 ----

  Future<QrSession> createQrSession() async {
    final root = await _postJson(asUrl(SklandRegion.skland, _genScanPath), {'appCode': _sklandAppCode});
    _ensureStatusZero(root, '生成扫码登录失败');
    final data = _obj(root['data']);
    final scanId = data['scanId']?.toString() ?? '';
    final scanUrl = data['scanUrl']?.toString() ?? '';
    if (scanId.trim().isEmpty || scanUrl.trim().isEmpty) throw const SklandException('生成扫码登录失败');
    return QrSession(scanId: scanId, scanUrl: scanUrl);
  }

  Future<QrStatus> pollQrStatus(String scanId) async {
    final url = '${asUrl(SklandRegion.skland, _scanStatusPath)}?scanId=${Uri.encodeComponent(scanId)}';
    final root = await _getJson(url);
    final status = _int(root['status']);
    final message = root['msg']?.toString();
    if (status == 100) return QrStatus(QrState.pendingScan, message: message);
    if (status == 101) return QrStatus(QrState.pendingConfirm, message: message);
    if (status == 0) {
      final scanCode = _obj(root['data'])['scanCode']?.toString() ?? '';
      if (scanCode.trim().isEmpty) throw const SklandException('获取扫码状态失败');
      final token = await _exchangeScanCode(scanCode);
      return QrStatus(QrState.confirmed, message: message, token: token);
    }
    return QrStatus(QrState.error, message: message ?? '扫码失败');
  }

  Future<String> _exchangeScanCode(String scanCode) async {
    final root = await _postJson(asUrl(SklandRegion.skland, _tokenByScanPath), {
      'scanCode': scanCode,
      'appCode': _sklandAppCode,
    });
    _ensureStatusZero(root, '扫码登录失败');
    return _requireToken(root, '扫码登录失败');
  }

  Future<String> phonePasswordLogin(String phone, String password) async {
    final root = await _postJson(asUrl(SklandRegion.skland, _tokenByPhonePasswordPath), {
      'phone': phone,
      'password': password,
    });
    _ensureStatusZero(root, '帐号密码登录失败');
    return _requireToken(root, '帐号密码登录失败');
  }

  Future<String> emailPasswordLogin(String email, String password) async {
    final root = await _postJson(asUrl(SklandRegion.skport, _tokenByEmailPasswordPath), {
      'email': email,
      'password': password,
    }, region: SklandRegion.skport);
    _ensureStatusZero(root, '邮箱密码登录失败');
    return _requireToken(root, '邮箱密码登录失败');
  }

  Future<void> sendPhoneCode(String phone) async {
    final root = await _postJson(asUrl(SklandRegion.skland, _sendPhoneCodePath), {'phone': phone, 'type': 2});
    _ensureStatusZero(root, '发送验证码失败');
  }

  Future<String> phoneCodeLogin(String phone, String code) async {
    final root = await _postJson(asUrl(SklandRegion.skland, _tokenByPhoneCodePath), {
      'phone': phone,
      'code': code,
      'appCode': _sklandAppCode,
    });
    _ensureStatusZero(root, '手机验证码登录失败');
    return _requireToken(root, '手机验证码登录失败');
  }

  // ---- 凭证与角色 ----

  Future<String> grant(String token, SklandRegion region) async {
    final Map<String, dynamic> root;
    try {
      root = await _postJson(asUrl(region, _grantPath), {
        'token': token,
        'appCode': region.isSkport ? _skportAppCode : _sklandAppCode,
        'type': 0,
      }, region: region);
    } on SklandException catch (e) {
      // 格式错误或失效的 token 会得到 HTTP 400，响应里只有字段校验信息。
      if (e.message.startsWith('请求失败: 4')) throw SklandException('token 无效或已过期（${e.message}）');
      rethrow;
    }
    _ensureStatusZero(root, '获取授权码失败');
    final code = _obj(root['data'])['code']?.toString();
    if (code == null || code.isEmpty) throw const SklandException('获取授权码失败');
    return code;
  }

  Future<CredentialResult> generateCredential(String code, SklandRegion region) async {
    final root = await _postJson(zonaiUrl(region, _generateCredentialPath), {'code': code, 'kind': 1}, region: region);
    _ensureCodeZero(root, '获取凭证失败');
    final data = _obj(root['data']);
    final cred = data['cred']?.toString() ?? '';
    final token = data['token']?.toString() ?? '';
    if (cred.trim().isEmpty || token.trim().isEmpty) throw const SklandException('获取凭证失败');
    return CredentialResult(cred: cred, userId: data['userId']?.toString() ?? '', token: token);
  }

  /// grant → credential，登录 token 换取签名凭证。
  Future<CredentialResult> login(String token, SklandRegion region) async =>
      generateCredential(await grant(token, region), region);

  Future<List<RoleBinding>> getRoleBindings(CredentialResult credential, SklandRegion region) async {
    final root = await _signed(zonaiUrl(region, _bindingPath), _bindingPath, credential, region);
    return parseRoleBindings(root);
  }

  Future<String> getWebSocketToken(CredentialResult credential, SklandRegion region) async {
    final root = await _signed(zonaiUrl(region, _webSocketTokenPath), _webSocketTokenPath, credential, region);
    _ensureCodeZero(root, '获取 WebSocket token 失败');
    final token = _obj(root['data'])['token']?.toString();
    if (token == null || token.isEmpty) throw const SklandException('获取 WebSocket token 失败');
    return token;
  }

  /// 是否已同意森空岛地图的“位置同步”政策；未同意时位置推送不会下发。
  Future<bool> hasAgreedPositionPolicy(CredentialResult credential, RoleBinding role, SklandRegion region) async {
    final query = 'roleId=${Uri.encodeComponent(role.roleId)}&serverId=${Uri.encodeComponent(role.serverId)}';
    final root = await _signed('${zonaiUrl(region, _mapMePath)}?$query', _mapMePath, credential, region);
    _ensureCodeZero(root, '获取终末地地图信息失败');
    return _obj(root['data'])['hasUserPositionAgree'] == true;
  }

  Future<void> agreePositionPolicy(CredentialResult credential, RoleBinding role, SklandRegion region) async {
    final body = jsonEncode({'roleId': role.roleId, 'serverId': role.serverId});
    final root = await _signed(
      zonaiUrl(region, _agreePolicyPath),
      _agreePolicyPath,
      credential,
      region,
      method: 'POST',
      bodyJson: body,
    );
    _ensureCodeZero(root, '同意终末地位置协议失败');
  }

  Future<List<ZiplineMark>> getZiplineMarks(
    CredentialResult credential,
    String mapId,
    RoleBinding role,
    SklandRegion region,
  ) async {
    final query =
        'mapId=${Uri.encodeComponent(mapId)}&roleId=${Uri.encodeComponent(role.roleId)}&serverId=${Uri.encodeComponent(role.serverId)}';
    final root = await _signed('${zonaiUrl(region, _markListPath)}?$query', _markListPath, credential, region);
    return parseZiplineMarks(root);
  }

  /// 读取服务器 `Date` 头计算本机时钟偏差；失败时保持原值。
  Future<void> syncNetworkTime() async {
    try {
      final response = await _dio.head<String>(zonaiUrl(SklandRegion.skland, '/'));
      final date = response.headers.value(HttpHeaders.dateHeader);
      if (date == null) return;
      networkTimeOffset = HttpDate.parse(date).toUtc().difference(DateTime.now().toUtc());
    } catch (_) {
      // 网络校时只是修正手段，失败不影响后续请求。
    }
  }

  // ---- 解析（公开以便测试） ----

  static List<RoleBinding> parseRoleBindings(Map<String, dynamic> root) {
    _ensureCodeZero(root, '未找到终末地角色');
    final result = <RoleBinding>[];
    final list = _obj(root['data'])['list'];
    if (list is List) {
      for (final app in list.whereType<Map>()) {
        if (app['appCode']?.toString().toLowerCase() != 'endfield') continue;
        final channelName = app['channelName']?.toString();
        final bindings = app['bindingList'];
        if (bindings is! List) continue;
        for (final binding in bindings.whereType<Map>()) {
          final role = binding['defaultRole'];
          if (role is! Map) continue;
          final serverId = role['serverId']?.toString() ?? '';
          final roleId = role['roleId']?.toString() ?? '';
          if (serverId.trim().isEmpty || roleId.trim().isEmpty) continue;
          result.add(
            RoleBinding(
              serverId: serverId,
              roleId: roleId,
              nickname: (role['nickname'] ?? role['nickName'])?.toString(),
              channelName: binding.containsKey('channelName') ? binding['channelName']?.toString() : channelName,
              level: role['level'] is num ? (role['level'] as num).toInt() : null,
            ),
          );
        }
      }
    }
    if (result.isEmpty) throw const SklandException('未找到终末地角色');
    return result;
  }

  static List<ZiplineMark> parseZiplineMarks(Map<String, dynamic> root) {
    _ensureCodeZero(root, '获取滑索标记失败');
    final saveMarks = _obj(root['data'])['saveMarks'];
    if (saveMarks is! List) throw const SklandException('获取滑索标记失败');
    final result = <ZiplineMark>[];
    for (final mark in saveMarks.whereType<Map>()) {
      final templateId = mark['templateId']?.toString().toLowerCase() ?? '';
      if (!ziplineTemplateIds.contains(templateId)) continue;
      final pos = mark['pos'];
      if (pos is! Map) continue;
      final x = pos['x'], y = pos['y'], z = pos['z'];
      if (x is! num || y is! num || z is! num) throw const SklandException('获取滑索标记失败');
      result.add(ZiplineMark(x.toDouble(), y.toDouble(), z.toDouble()));
    }
    return result;
  }

  // ---- 传输 ----

  Map<String, String> _languageHeaders(SklandRegion region) {
    final language = skLanguage(region, languageProvider?.call());
    return {'sk-language': ?language};
  }

  Future<Map<String, dynamic>> _postJson(
    String url,
    Map<String, Object?> body, {
    SklandRegion region = SklandRegion.skland,
  }) => _send(
    url,
    method: 'POST',
    data: jsonEncode(body),
    headers: {..._languageHeaders(region), Headers.contentTypeHeader: 'application/json; charset=utf-8'},
  );

  Future<Map<String, dynamic>> _getJson(String url) => _send(url, method: 'GET', headers: const {});

  Future<Map<String, dynamic>> _signed(
    String url,
    String path,
    CredentialResult credential,
    SklandRegion region, {
    String method = 'GET',
    String? bodyJson,
  }) {
    final timestamp = SklandSigner.timestamp(DateTime.now().toUtc(), offset: networkTimeOffset);
    final queryOrBody = method == 'POST' ? (bodyJson ?? '') : _queryOf(url);
    final sign = SklandSigner.sign(path: path, queryOrBody: queryOrBody, timestamp: timestamp, token: credential.token);
    return _send(
      url,
      method: method,
      data: method == 'POST' ? (bodyJson ?? '') : null,
      headers: {
        ..._languageHeaders(region),
        'platform': '3',
        'timestamp': timestamp,
        'dId': '',
        'vName': '1.0.0',
        'Cred': credential.cred,
        'Sign': sign,
        Headers.contentTypeHeader: 'application/json;charset=UTF-8',
      },
    );
  }

  static String _queryOf(String url) {
    final index = url.indexOf('?');
    return index < 0 ? '' : url.substring(index + 1);
  }

  Future<Map<String, dynamic>> _send(
    String url, {
    required String method,
    required Map<String, String> headers,
    Object? data,
  }) async {
    final Response<String> response;
    try {
      response = await _dio.request<String>(
        url,
        data: data,
        options: Options(method: method, headers: headers),
      );
    } on DioException catch (e) {
      throw SklandException(switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => '连接森空岛超时，请检查网络',
        _ => '无法连接到森空岛，请检查网络',
      });
    }
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) throw SklandException('请求失败: $status');
    final text = response.data ?? '';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // 走到下面统一报错。
    }
    throw const SklandException('森空岛返回了无法解析的数据');
  }

  static Map<String, dynamic> _obj(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

  static int? _int(Object? value) => value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  static String _requireToken(Map<String, dynamic> root, String error) {
    final token = _obj(root['data'])['token']?.toString();
    if (token == null || token.isEmpty) throw SklandException(error);
    return token;
  }

  static String _errorMessage(Map<String, dynamic> root, String fallback) {
    for (final key in ['msg', 'message']) {
      final value = root[key]?.toString();
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return fallback;
  }

  static void _ensureStatusZero(Map<String, dynamic> root, String error) {
    if (_int(root['status']) != 0) throw SklandException(_errorMessage(root, error));
  }

  static void _ensureCodeZero(Map<String, dynamic> root, String error) {
    if (_int(root['code']) != 0) throw SklandException(_errorMessage(root, error));
  }
}
