import 'dart:async';

import 'package:dio/dio.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/integrations/skland/position_socket.dart';
import 'package:zipliner_client/integrations/skland/skland_client.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

import 'fake_adapter.dart';

/// 模拟森空岛接口：一个 token 下有一个终末地角色，滑索标记在 (0,10,0)。
FakeResponse sklandResponder(RequestOptions request, {bool agreed = true}) {
  final path = request.uri.path;
  if (request.method == 'HEAD') return const FakeResponse('');
  if (path.endsWith('/grant')) {
    return FakeResponse.json({
      'status': 0,
      'data': {'code': 'c'},
    });
  }
  if (path.endsWith('/generate_cred_by_code')) {
    return FakeResponse.json({
      'code': 0,
      'data': {'cred': 'cred', 'userId': '1', 'token': 'sign-token'},
    });
  }
  if (path.endsWith('/player/binding')) {
    return FakeResponse.json({
      'code': 0,
      'data': {
        'list': [
          {
            'appCode': 'endfield',
            'channelName': '官服',
            'bindingList': [
              {
                'defaultRole': {
                  'serverId': '1',
                  'roleId': '42',
                  'nickname': '管理员',
                },
              },
            ],
          },
        ],
      },
    });
  }
  if (path.endsWith('/map/me')) {
    return FakeResponse.json({
      'code': 0,
      'data': {'hasUserPositionAgree': agreed},
    });
  }
  if (path.endsWith('/agree-policy')) return FakeResponse.json({'code': 0});
  if (path.endsWith('/websocket/token')) {
    return FakeResponse.json({
      'code': 0,
      'data': {'token': 'ws-token'},
    });
  }
  if (path.endsWith('/mark/list')) {
    return FakeResponse.json({
      'code': 0,
      'data': {
        'saveMarks': [
          {
            'templateId': '0f45150a59b97bd0de9a4eed7a0fbf23',
            'pos': {'x': 0, 'y': 10, 'z': 0},
          },
        ],
      },
    });
  }
  return FakeResponse.text('', status: 404);
}

/// 不联网的 WebSocket：由测试推送坐标，调用 [end] 结束。
class FakeSocket extends PositionSocket {
  final _done = Completer<String?>();
  PositionCallback? _onPosition;
  String? token;
  RoleBinding? role;

  void push(double x, double y, double z, {String? mapId = 'map01'}) =>
      _onPosition?.call(PositionSnapshot(x, y, z), mapId, null);

  void end(String reason) => _done.complete(reason);

  @override
  Future<String?> run({
    required String websocketToken,
    required RoleBinding role,
    required SklandRegion region,
    required PositionCallback onPosition,
    void Function()? onSubscribed,
    String? language,
  }) {
    token = websocketToken;
    this.role = role;
    _onPosition = onPosition;
    onSubscribed?.call();
    return _done.future;
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete(null);
  }
}

PositionMonitor monitorWith(
  FakeAdapter adapter, {
  List<StoredToken> tokens = const [],
  FakeSocket? socket,
}) {
  final dio = Dio(
    BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true),
  )..httpClientAdapter = adapter;
  return PositionMonitor(
    client: SklandClient(dio: dio),
    tokens: TokenRepository(MemoryTokenStore(tokens)),
    captureDirectory: () async => '.',
    socketFactory: () => socket ?? FakeSocket(),
  );
}

const token = StoredToken(
  id: 't1',
  token: 'user-token',
  region: SklandRegion.skland,
);

Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
