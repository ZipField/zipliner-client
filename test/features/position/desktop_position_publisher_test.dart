import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signalr_netcore/signalr_client.dart';
import 'package:zipliner_client/features/position/connections/desktop_position_publisher.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';
import 'package:zipliner_client/shared/http/api_client.dart';

import '../../support/position_fakes.dart' show FakeSocket, pumpUntil;

class _Api extends ApiClient {
  _Api([String baseUrl = 'https://api.test'])
    : super(baseUrl: baseUrl, cookieJar: CookieJar());

  @override
  Future<String?> sessionToken() async => 'session';
}

class _NoProxyOverrides extends HttpOverrides {}

class _LocalHubServer {
  _LocalHubServer(this.server, this.negotiateDelay) {
    server.listen((request) => unawaited(_handle(request)));
  }

  final HttpServer server;
  final Duration negotiateDelay;
  final invocations = <String>[];
  int negotiateCount = 0;
  int webSocketCount = 0;
  int sseCount = 0;
  String get baseUrl => 'http://${server.address.address}:${server.port}';

  static Future<_LocalHubServer> bind(Duration delay) async => _LocalHubServer(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    delay,
  );

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path.endsWith('/negotiate')) {
      negotiateCount++;
      await Future<void>.delayed(negotiateDelay);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'negotiateVersion': 1,
          'connectionId': 'connection',
          'connectionToken': 'token',
          'availableTransports': [
            {
              'transport': 'ServerSentEvents',
              'transferFormats': ['Text'],
            },
            {
              'transport': 'WebSockets',
              'transferFormats': ['Text', 'Binary'],
            },
          ],
        }),
      );
      await request.response.close();
      return;
    }
    if ((request.headers.value(HttpHeaders.upgradeHeader) ?? '')
        .toLowerCase()
        .contains('websocket')) {
      final socket = await WebSocketTransformer.upgrade(request);
      webSocketCount++;
      final pending = StringBuffer();
      socket.listen((data) {
        pending.write(data is String ? data : utf8.decode(data as List<int>));
        while (true) {
          final buffered = pending.toString();
          final separator = buffered.indexOf('\u001e');
          if (separator < 0) break;
          final frame = buffered.substring(0, separator);
          pending
            ..clear()
            ..write(buffered.substring(separator + 1));
          if (frame.isEmpty) continue;
          final message = jsonDecode(frame) as Map<String, dynamic>;
          if (message.containsKey('protocol')) {
            socket.add('{}\u001e');
            continue;
          }
          if (message['type'] != 1) continue;
          final target = message['target'] as String;
          invocations.add(target);
          final invocationId = message['invocationId'] as String?;
          if (invocationId == null) continue;
          final Object? result = target == 'BeginDesktopPositionPublisher'
              ? {
                  'leaseId': 'local-lease',
                  'roleId': 'role-1',
                  'serverId': 'server-1',
                  'viewers': false,
                }
              : null;
          socket.add(
            '${jsonEncode({'type': 3, 'invocationId': invocationId, 'result': result})}\u001e',
          );
        }
      });
      return;
    }
    if (request.uri.path.endsWith('/hubs/data')) sseCount++;
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> close() async => server.close(force: true);
}

class _Hub implements HubConnection {
  @override
  HubConnectionState state = HubConnectionState.Disconnected;
  final invocations = <String>[];
  final uploads = <Map<String, Object?>>[];
  void Function({Exception? error})? _onClose;
  void Function(List<Object?>? arguments)? _viewerChanged;
  Completer<Object?>? uploadGate;
  Completer<Object?>? beginGate;
  bool failUploads = false;
  bool viewers = false;
  int endCalls = 0;

  @override
  Future<void>? start() async => state = HubConnectionState.Connected;

  @override
  Future<void> stop() async => state = HubConnectionState.Disconnected;

  @override
  void onclose(void Function({Exception? error}) callback) =>
      _onClose = callback;

  @override
  void on(String methodName, void Function(List<Object?>? arguments) callback) {
    if (methodName == 'DesktopViewerStateChanged') _viewerChanged = callback;
  }

  @override
  Future<Object?> invoke(String methodName, {List<Object>? args}) async {
    invocations.add(methodName);
    if (methodName == 'BeginDesktopPositionPublisher') {
      final gate = beginGate;
      if (gate != null) return gate.future;
      return {
        'leaseId': 'lease-1',
        'roleId': 'role-1',
        'serverId': 'server-1',
        'viewers': viewers,
      };
    }
    if (methodName == 'PublishDesktopPosition') {
      uploads.add(Map<String, Object?>.from(args![1] as Map));
      if (failUploads) throw StateError('hub unavailable');
      final gate = uploadGate;
      uploadGate = null;
      return gate?.future;
    }
    if (methodName == 'EndDesktopPosition') endCalls++;
    return null;
  }

  void setViewers(bool value) {
    viewers = value;
    _viewerChanged?.call([
      {
        'leaseId': 'lease-1',
        'roleId': 'role-1',
        'serverId': 'server-1',
        'viewers': value,
      },
    ]);
  }

  void drop() {
    state = HubConnectionState.Disconnected;
    _onClose?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 10));
  while (!condition() && DateTime.now().isBefore(limit)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (!condition()) throw TimeoutException('condition not reached');
}

const _role = RoleSession(
  tokenId: 'account-token',
  region: SklandRegion.skland,
  gameAccountId: 'game-account',
  binding: RoleBinding(roleId: 'role-1', serverId: 'server-1'),
);

void main() {
  testWidgets(
    'unchanged coordinates are resent once after ten minutes of viewer presence',
    (tester) async {
      final hub = _Hub()..viewers = true;
      final publisher = DesktopPositionPublisher(
        _Api(),
        _role,
        hubFactory: () => hub,
      );
      publisher.start();
      await tester.pump();
      publisher.offer(const PositionSnapshot(1, 2, 3), 'map-a', 'level-a');
      await tester.pump();
      expect(hub.uploads, hasLength(1));
      final officialFrames = Timer.periodic(const Duration(seconds: 1), (_) {
        publisher.offer(const PositionSnapshot(1, 2, 3), 'map-a', 'level-a');
      });

      await tester.pump(const Duration(minutes: 9));
      expect(hub.uploads, hasLength(1));
      await tester.pump(const Duration(minutes: 1));
      officialFrames.cancel();
      expect(hub.uploads, hasLength(2));
      expect(hub.uploads.last['sequence'], 2);
      await publisher.close();
    },
  );

  test(
    'publisher uploads positions only while a matching website viewer exists',
    () async {
      final hub = _Hub();
      final publisher = DesktopPositionPublisher(
        _Api(),
        _role,
        hubFactory: () => hub,
      );
      publisher.start();
      await pumpUntil(
        () => hub.invocations.contains('BeginDesktopPositionPublisher'),
      );

      publisher.offer(const PositionSnapshot(1, 2, 3), 'map-a', 'level-a');
      expect(hub.uploads, isEmpty);

      hub.setViewers(true);
      await pumpUntil(() => hub.uploads.length == 1);
      expect(hub.uploads.single, containsPair('x', 1));
      expect(hub.uploads.single, containsPair('mapId', 'map-a'));

      hub.setViewers(false);
      publisher.offer(const PositionSnapshot(4, 5, 6), 'map-a', 'level-a');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(hub.uploads, hasLength(1));
      await publisher.close();
    },
  );

  test('website sync state stays hidden until the upload is acknowledged and clears when viewers leave', () async {
    final hub = _Hub();
    var syncChanges = 0;
    final publisher = DesktopPositionPublisher(
      _Api(),
      _role,
      hubFactory: () => hub,
      onSyncChanged: () => syncChanges++,
    );
    publisher.start();
    await pumpUntil(
      () => hub.invocations.contains('BeginDesktopPositionPublisher'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    publisher.offer(const PositionSnapshot(1, 2, 3), 'map-a', 'level-a');
    expect(publisher.syncedToWebsite, isFalse);
    expect(hub.uploads, isEmpty);

    final upload = hub.uploadGate = Completer<Object?>();
    hub.setViewers(true);
    await pumpUntil(() => hub.uploads.length == 1);
    expect(publisher.syncedToWebsite, isFalse);
    upload.complete(null);
    await pumpUntil(() => publisher.syncedToWebsite);
    expect(syncChanges, 1);

    hub.setViewers(false);
    expect(publisher.syncedToWebsite, isFalse);
    expect(syncChanges, 2);
    await publisher.close();
  });

  test('stale upload acknowledgement preserves the new viewer upload and cannot restore sync after Hub loss', () async {
    final hub = _Hub()..viewers = true;
    final publisher = DesktopPositionPublisher(
      _Api(),
      _role,
      hubFactory: () => hub,
    );
    publisher.start();
    await pumpUntil(
      () => hub.invocations.contains('BeginDesktopPositionPublisher'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final firstAck = hub.uploadGate = Completer<Object?>();
    publisher.offer(const PositionSnapshot(1, 2, 3), 'map-a', 'level-a');
    await pumpUntil(() => hub.uploads.length == 1);
    hub.setViewers(false);
    expect(publisher.syncedToWebsite, isFalse);

    final currentAck = hub.uploadGate = Completer<Object?>();
    hub.setViewers(true);
    firstAck.complete(null);
    await pumpUntil(() => hub.uploads.length == 2);
    expect(publisher.syncedToWebsite, isFalse);
    currentAck.complete(null);
    await pumpUntil(() => publisher.syncedToWebsite);

    final lateAck = hub.uploadGate = Completer<Object?>();
    publisher.offer(const PositionSnapshot(4, 5, 6), 'map-a', 'level-a');
    await pumpUntil(() => hub.uploads.length == 3);
    hub.drop();
    expect(publisher.syncedToWebsite, isFalse);
    lateAck.complete(null);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(publisher.syncedToWebsite, isFalse);
    await publisher.close();
  });

  test(
    'viewer event received before ticket response is applied to that lease',
    () async {
      final hub = _Hub()..beginGate = Completer<Object?>();
      final publisher = DesktopPositionPublisher(
        _Api(),
        _role,
        hubFactory: () => hub,
      );
      publisher.start();
      await pumpUntil(
        () => hub.invocations.contains('BeginDesktopPositionPublisher'),
      );
      hub.setViewers(true);
      hub.beginGate!.complete({
        'leaseId': 'lease-1',
        'roleId': 'role-1',
        'serverId': 'server-1',
        'viewers': false,
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      publisher.offer(const PositionSnapshot(1, 0, 0), null, null);
      await pumpUntil(() => hub.uploads.isNotEmpty);
      expect(hub.uploads, hasLength(1));
      await publisher.close();
    },
  );

  test('returning to the in-flight position uploads the final position after a slow RPC', () async {
    final hub = _Hub()..viewers = true;
    final publisher = DesktopPositionPublisher(
      _Api(),
      _role,
      hubFactory: () => hub,
    );
    publisher.start();
    await pumpUntil(
      () => hub.invocations.contains('BeginDesktopPositionPublisher'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    publisher.offer(const PositionSnapshot(1, 0, 0), null, null);
    await pumpUntil(() => hub.uploads.length == 1);
    final gate = hub.uploadGate = Completer<Object?>();
    publisher.offer(const PositionSnapshot(2, 0, 0), null, null);
    await pumpUntil(() => hub.uploads.length == 2);
    publisher.offer(const PositionSnapshot(1, 0, 0), null, null);
    gate.complete(null);
    await pumpUntil(() => hub.uploads.length == 3);
    expect(hub.uploads.map((upload) => upload['x']), [1, 2, 1]);
    await publisher.close();
  });

  test('slow or failed Hub upload never blocks local coordinate delivery or closes its socket', () async {
    final hub = _Hub()..viewers = true;
    final gate = hub.uploadGate = Completer<Object?>();
    final publisher = DesktopPositionPublisher(
      _Api(),
      _role,
      hubFactory: () => hub,
    );
    final socket = FakeSocket();
    final received = <double>[];
    socket.run(
      websocketToken: 'official-token',
      role: _role.binding,
      region: _role.region,
      onPosition: (position, map, level) {
        received.add(position.x);
        publisher.offer(position, map, level);
      },
    );
    publisher.start();
    await pumpUntil(
      () => hub.invocations.contains('BeginDesktopPositionPublisher'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    socket.push(1, 0, 0);
    socket.push(2, 0, 0);
    expect(received, [1, 2]);
    expect(hub.uploads, hasLength(1));
    gate.complete(null);
    await pumpUntil(() => hub.uploads.length == 2);
    hub.failUploads = true;
    socket.push(3, 0, 0);
    await pumpUntil(() => hub.state == HubConnectionState.Disconnected);
    socket.push(4, 0, 0);

    expect(received, [1, 2, 3, 4]);
    expect(socket.token, 'official-token');
    await publisher.close();
    await socket.close();
  });

  test('Hub disconnection does not own or close the official socket', () async {
    final hub = _Hub()..viewers = true;
    final publisher = DesktopPositionPublisher(
      _Api(),
      _role,
      hubFactory: () => hub,
    );
    final socket = FakeSocket();
    final received = <double>[];
    socket.run(
      websocketToken: 'official-token',
      role: _role.binding,
      region: _role.region,
      onPosition: (position, _, _) => received.add(position.x),
    );
    publisher.start();
    await pumpUntil(
      () => hub.invocations.contains('BeginDesktopPositionPublisher'),
    );

    hub.drop();
    socket.push(7, 8, 9);

    expect(received, [7]);
    expect(socket.token, 'official-token');
    expect(
      hub.endCalls,
      0,
      reason: 'unexpected Hub loss must not hand the lease back',
    );
    await publisher.close();
    await socket.close();
  });

  test('real SignalR publisher completes negotiation slower than two seconds over WebSockets', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await _LocalHubServer.bind(
        const Duration(milliseconds: 2400),
      );
      try {
        final hub = DesktopPositionPublisher(_Api(server.baseUrl), _role);
        hub.start();
        await _waitFor(
          () => server.invocations.contains('BeginDesktopPositionPublisher'),
        );
        expect(server.negotiateCount, 1);
        expect(server.webSocketCount, 1);
        expect(server.sseCount, 0);
        expect(
          server.invocations,
          containsAll(['SendAuth', 'BeginDesktopPositionPublisher']),
        );
        await hub.close();
      } finally {
        await server.close();
      }
    }, _NoProxyOverrides());
  });
}
