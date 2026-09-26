import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/position/position_monitor.dart';
import 'package:zipliner_client/position/token_store.dart';
import 'package:zipliner_client/skland/position_socket.dart';
import 'package:zipliner_client/skland/skland_client.dart';
import 'package:zipliner_client/skland/skland_models.dart';

import 'support/fake_adapter.dart';

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
                'defaultRole': {'serverId': '1', 'roleId': '42', 'nickname': '管理员'},
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

PositionMonitor monitorWith(FakeAdapter adapter, {List<StoredToken> tokens = const [], FakeSocket? socket}) {
  final dio = Dio(BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true))
    ..httpClientAdapter = adapter;
  return PositionMonitor(
    client: SklandClient(dio: dio),
    tokens: TokenRepository(MemoryTokenStore(tokens)),
    captureDirectory: () async => '.',
    socketFactory: () => socket ?? FakeSocket(),
  );
}

const token = StoredToken(id: 't1', token: 'user-token', region: SklandRegion.skland);

Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('没有 token 时提示登录', () async {
    final monitor = monitorWith(FakeAdapter(sklandResponder));
    await monitor.start();
    expect(monitor.status, '未登录');
    expect(monitor.warning, '登录后才能连接坐标同步');
    expect(monitor.hasTokens, isFalse);
  });

  test('连接流程：加载角色 → 取 ws token → 接收坐标与 mapId', () async {
    final socket = FakeSocket();
    final monitor = monitorWith(FakeAdapter(sklandResponder), tokens: [token], socket: socket);
    monitor.requestInterval = const Duration(seconds: 3);
    final run = monitor.start();
    await pumpUntil(() => socket.token != null);

    expect(socket.token, 'ws-token');
    expect(socket.requestInterval, const Duration(seconds: 3));
    monitor.requestInterval = const Duration(seconds: 5);
    expect(socket.requestInterval, const Duration(seconds: 5));
    expect(socket.role!.roleId, '42');
    expect(monitor.activeRole!.displayName, '官服 - 管理员');
    expect(monitor.status, '已连接：官服 - 管理员，等待坐标...');

    socket.push(1, 2, 3);
    expect(monitor.status, '坐标已更新');
    expect(monitor.mapId, 'map01');
    socket.push(4, 5, 6, mapId: null);
    expect(monitor.mapId, 'map01', reason: '消息缺少 mapId 时保留上一次的值');
    expect(monitor.position!.x, 4);

    socket.end('WebSocket 已关闭');
    await run;
    expect(monitor.status, 'WebSocket 已关闭');
    expect(monitor.isError, isTrue);
    expect(monitor.problem!.title, '连接中断');
    expect(monitor.nextRetryAt, isNotNull, reason: '连接中断后应自动重连');
    await monitor.disconnect();
    expect(monitor.nextRetryAt, isNull);
  });

  test('未同意位置政策时停下等待用户确认，确认后调用同意接口并连接', () async {
    var agreed = false;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/agree-policy')) agreed = true;
      return sklandResponder(request, agreed: agreed);
    });
    final socket = FakeSocket();
    final monitor = monitorWith(adapter, tokens: [token], socket: socket);

    await monitor.start();
    expect(monitor.policyRequired, isTrue);
    expect(socket.token, isNull);

    unawaited(monitor.agreePolicyAndConnect());
    await pumpUntil(() => socket.token != null);
    expect(agreed, isTrue);
    expect(monitor.policyRequired, isFalse);
    await monitor.disconnect();
  });

  test('采集：拿到 mapId 后获取滑索标记并实时识别', () async {
    final socket = FakeSocket();
    final monitor = monitorWith(FakeAdapter(sklandResponder), tokens: [token], socket: socket);
    final detections = <String>[];
    monitor.onDetection = (stop) => detections.add(stop.label);
    unawaited(monitor.start());
    await pumpUntil(() => socket.token != null);

    await monitor.startCapture();
    expect(monitor.warning, '已开始采集；等待地图、登录和角色信息后再获取滑索数据');

    socket.push(1, 13.5, 1);
    await pumpUntil(() => monitor.detector != null);
    expect(monitor.warning, '已获取滑索数据：1 个，停在滑索上等待识别');

    socket.push(1, 13.5, 1);
    socket.push(1.05, 13.5, 1);
    expect(detections, ['(1,10,1,北)']);
    expect(monitor.warning, '已识别第 1 个滑索：(1,10,1,北)');

    await monitor.manualDetect();
    expect(monitor.lookupResult!.toTupleText(), '(1,10,1,北)');

    monitor.stopCapture();
    expect(monitor.warning, '已停止采集');
    await monitor.disconnect();
  });
}
