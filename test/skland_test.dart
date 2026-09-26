import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/skland/position_socket.dart';
import 'package:zipliner_client/skland/skland_client.dart';
import 'package:zipliner_client/skland/skland_models.dart';
import 'package:zipliner_client/skland/skland_signer.dart';

import 'support/fake_adapter.dart';

const _cred = CredentialResult(cred: 'cred-1', userId: 'u1', token: 'abc123token');
const _role = RoleBinding(serverId: '1', roleId: '123');

SklandClient _client(FakeAdapter adapter) {
  final dio = Dio(BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true))
    ..httpClientAdapter = adapter;
  return SklandClient(dio: dio);
}

void main() {
  group('SklandSigner', () {
    // 期望值由 Node.js crypto 按后端 CreateSign 的算法独立计算。
    test('GET 签名 = md5(hex(hmacSha256(token, path+query+timestamp+headerJson)))', () {
      expect(
        SklandSigner.sign(
          path: '/web/v1/game/endfield/map/mark/list',
          queryOrBody: 'mapId=map01&roleId=123&serverId=1',
          timestamp: '1790000000',
          token: 'abc123token',
        ),
        '97de2798f54d255f7e2e72a594f9abbd',
      );
    });

    test('POST 签名使用 JSON 请求体', () {
      expect(
        SklandSigner.sign(
          path: '/web/v1/game/endfield/map/agree-policy',
          queryOrBody: jsonEncode({'roleId': '123', 'serverId': '1'}),
          timestamp: '1790000000',
          token: 'abc123token',
        ),
        'f20e15cd0f410bd9c3cf95aff967aba5',
      );
    });

    test('时间戳比当前时间早 3 秒并叠加网络时间偏差', () {
      final now = DateTime.utc(2026, 9, 26, 0, 0, 10);
      expect(SklandSigner.timestamp(now), '${now.millisecondsSinceEpoch ~/ 1000 - 3}');
      expect(
        SklandSigner.timestamp(now, offset: const Duration(seconds: 100)),
        '${now.millisecondsSinceEpoch ~/ 1000 + 97}',
      );
    });
  });

  group('SklandClient', () {
    test('签名请求带上 Cred/Sign/timestamp 等头，查询串原样参与签名', () async {
      final adapter = FakeAdapter(
        (_) => FakeResponse.json({
          'code': 0,
          'data': {
            'saveMarks': [
              {
                'templateId': '0F45150A59B97BD0DE9A4EED7A0FBF23',
                'pos': {'x': 10, 'y': 5.5, 'z': 20},
              },
              {
                'templateId': 'other',
                'pos': {'x': 1, 'y': 1, 'z': 1},
              },
              {
                'templateId': '5d53bdb714ba42c1e1a1b748b55b686f',
                'pos': {'x': -3.25, 'y': 0, 'z': 7},
              },
            ],
          },
        }),
      );
      final marks = await _client(adapter).getZiplineMarks(_cred, 'map01', _role, SklandRegion.skland);

      expect(marks.map((m) => (m.x, m.y, m.z)), [(10.0, 5.5, 20.0), (-3.25, 0.0, 7.0)]);
      final request = adapter.requests.single;
      expect(
        request.uri.toString(),
        'https://zonai.skland.com/web/v1/game/endfield/map/mark/list?mapId=map01&roleId=123&serverId=1',
      );
      final timestamp = request.headers['timestamp'] as String;
      expect(request.headers['Cred'], 'cred-1');
      expect(request.headers['platform'], '3');
      expect(request.headers['vName'], '1.0.0');
      expect(
        request.headers['Sign'],
        SklandSigner.sign(
          path: '/web/v1/game/endfield/map/mark/list',
          queryOrBody: 'mapId=map01&roleId=123&serverId=1',
          timestamp: timestamp,
          token: _cred.token,
        ),
      );
    });

    test('登录流程：grant → generate_cred_by_code，SKPort 使用国际服域名与 appCode', () async {
      final adapter = FakeAdapter((request) {
        if (request.path.endsWith('/grant')) {
          return FakeResponse.json({
            'status': 0,
            'data': {'code': 'grant-code'},
          });
        }
        return FakeResponse.json({
          'code': 0,
          'data': {'cred': 'c', 'userId': '9', 'token': 't'},
        });
      });
      final credential = await _client(adapter).login('user-token', SklandRegion.skport);

      expect(credential.cred, 'c');
      expect(adapter.requests[0].uri.toString(), 'https://as.gryphline.com/user/oauth2/v2/grant');
      expect(jsonDecode(adapter.requests[0].data as String), {
        'token': 'user-token',
        'appCode': '6eb76d4e13aa36e6',
        'type': 0,
      });
      expect(adapter.requests[0].headers['sk-language'], 'zh_Hans');
      expect(adapter.requests[1].uri.toString(), 'https://zonai.skport.com/api/v1/user/auth/generate_cred_by_code');
      expect(jsonDecode(adapter.requests[1].data as String), {'code': 'grant-code', 'kind': 1});
    });

    test('业务错误使用服务端 msg，HTTP 错误返回状态码', () async {
      final bad = _client(FakeAdapter((_) => FakeResponse.json({'status': 1, 'msg': '密码错误'})));
      await expectLater(
        bad.phonePasswordLogin('13800000000', 'x'),
        throwsA(isA<SklandException>().having((e) => e.message, 'message', '密码错误')),
      );
      final down = _client(FakeAdapter((_) => FakeResponse.text('', status: 502)));
      await expectLater(
        down.sendPhoneCode('13800000000'),
        throwsA(isA<SklandException>().having((e) => e.message, 'message', '请求失败: 502')),
      );
    });

    test('扫码状态：100/101 等待，0 时自动换取 token', () async {
      var polls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/scan_status')) {
          polls++;
          return polls == 1
              ? FakeResponse.json({'status': 100, 'msg': '等待扫码'})
              : FakeResponse.json({
                  'status': 0,
                  'data': {'scanCode': 'sc'},
                });
        }
        return FakeResponse.json({
          'status': 0,
          'data': {'token': 'final-token'},
        });
      });
      final client = _client(adapter);

      final first = await client.pollQrStatus('scan-1');
      expect(first.state, QrState.pendingScan);
      final second = await client.pollQrStatus('scan-1');
      expect(second.state, QrState.confirmed);
      expect(second.token, 'final-token');
      expect(jsonDecode(adapter.requests.last.data as String), {'scanCode': 'sc', 'appCode': '4ca99fa6b56cc2ba'});
    });

    test('parseRoleBindings 只取 endfield 的默认角色', () {
      final roles = SklandClient.parseRoleBindings({
        'code': 0,
        'data': {
          'list': [
            {
              'appCode': 'arknights',
              'bindingList': [
                {
                  'defaultRole': {'serverId': '1', 'roleId': 'x'},
                },
              ],
            },
            {
              'appCode': 'endfield',
              'channelName': '官服',
              'bindingList': [
                {
                  'defaultRole': {'serverId': '1', 'roleId': '100', 'nickname': '管理员', 'level': 30},
                },
                {'defaultRole': null},
                {
                  'channelName': 'B服',
                  'defaultRole': {'serverId': '2', 'roleId': '200', 'nickName': '二号'},
                },
              ],
            },
          ],
        },
      });
      expect(roles.map((r) => r.displayName), ['官服 - 管理员', 'B服 - 二号']);
      expect(roles.first.level, 30);
      expect(
        () => SklandClient.parseRoleBindings({
          'code': 0,
          'data': {'list': []},
        }),
        throwsA(isA<SklandException>()),
      );
    });
  });

  group('PositionMessage', () {
    test('解析坐标与 mapId', () {
      final m = PositionMessage.parse(
        '{"type":1012,"data":{"pos":{"x":1.5,"y":2,"z":-3},"mapId":"map01","levelId":"lv1"},"msgId":"a"}',
      );
      expect(m.type, WsMessageType.position);
      expect((m.position!.x, m.position!.y, m.position!.z), (1.5, 2.0, -3.0));
      expect(m.mapId, 'map01');
      expect(m.levelId, 'lv1');
    });

    test('没有 mapId 时仍能解析坐标', () {
      final m = PositionMessage.parse('{"type":1012,"data":{"pos":{"x":1,"y":2,"z":3}}}');
      expect(m.position, isNotNull);
      expect(m.mapId, isNull);
    });

    test('远端关闭与无效消息', () {
      expect(PositionMessage.parse('{"type":6,"data":{"code":401,"message":"bye"}}').error, contains('code=401'));
      expect(PositionMessage.parse('not json').type, WsMessageType.remoteClose);
      expect(PositionMessage.parse('{"type":2}').type, WsMessageType.authAck);
    });

    test('msgId 为 8 位字母数字', () {
      expect(PositionSocket.createMsgId(), matches(RegExp(r'^[a-zA-Z0-9]{8}$')));
    });
  });
}
