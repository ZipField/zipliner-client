import 'dart:async';

import 'package:signalr_netcore/signalr_client.dart';
import 'package:signalr_netcore/ihub_protocol.dart';
import 'package:zipliner_client/shared/http/api_client.dart';
import 'package:zipliner_client/shared/logging/app_log.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

/// Optional website upload. This class never owns or closes the official socket.
class DesktopPositionPublisher {
  DesktopPositionPublisher(
    this.api,
    this.role, {
    this.hubFactory,
    this.onSyncChanged,
  });
  final ApiClient api;
  final RoleSession role;
  final HubConnection Function()? hubFactory;
  final void Function()? onSyncChanged;
  bool _syncedToWebsite = false;
  int _syncRevision = 0;
  bool get syncedToWebsite => _syncedToWebsite;

  void _setSynced(bool value) {
    if (_syncedToWebsite == value) return;
    _syncedToWebsite = value;
    onSyncChanged?.call();
  }

  static const idleRefresh = Duration(minutes: 10);
  HubConnection? _hub;
  String? _lease;
  bool _closed = false;
  bool _viewers = false;
  bool _sending = false;
  int _generation = 0;
  int _sequence = 0;
  int _attempt = 0;
  Timer? _retry;
  Timer? _refresh;
  Map<String, Object?>? _latest;
  Map<String, Object?>? _sent;
  Map<String, Object?>? _pending;
  final _positionAge = Stopwatch();
  final _uploadAge = Stopwatch();
  Future<void>? _closing;
  Map? _earlyViewerState;

  bool matches(RoleSession other) =>
      role.key == other.key &&
      role.gameAccountId == other.gameAccountId &&
      role.region == other.region;

  void start() => unawaited(_connect());

  void pause() {
    _syncRevision++;
    _setSynced(false);
    _latest = _pending = _sent = null;
    _refresh?.cancel();
    _positionAge.stop();
    _positionAge.reset();
  }

  void offer(PositionSnapshot position, String? map, String? level) {
    if (_closed) return;
    _positionAge
      ..reset()
      ..start();
    _latest = {
      'x': position.x,
      'y': position.y,
      'z': position.z,
      'mapId': map,
      'levelId': level,
    };
    _queue();
  }

  bool _same(Map<String, Object?>? a, Map<String, Object?>? b) =>
      a != null &&
      b != null &&
      a.length == b.length &&
      a.keys.every((key) => a[key] == b[key]);

  void _queue({bool force = false}) {
    if (_closed ||
        !_viewers ||
        _lease == null ||
        _latest == null ||
        !_positionAge.isRunning ||
        _positionAge.elapsed >= const Duration(seconds: 30)) {
      return;
    }
    if (!_sending &&
        !force &&
        _same(_latest, _sent) &&
        _uploadAge.elapsed < idleRefresh) {
      _pending = null;
      return;
    }
    _pending = _latest;
    unawaited(_send());
  }

  Future<void> _send() async {
    if (_sending) return;
    final hub = _hub;
    final lease = _lease;
    final generation = _generation;
    if (hub == null || lease == null) return;
    _sending = true;
    try {
      while (!_closed &&
          generation == _generation &&
          _viewers &&
          _pending != null) {
        final frame = _pending!;
        final syncRevision = _syncRevision;
        _pending = null;
        await hub
            .invoke(
              'PublishDesktopPosition',
              args: [
                lease,
                {...frame, 'sequence': ++_sequence},
              ],
            )
            .timeout(const Duration(seconds: 20));
        if (_closed || generation != _generation) return;
        _sent = syncRevision == _syncRevision ? frame : null;
        if (_viewers && syncRevision == _syncRevision) _setSynced(true);
        _uploadAge
          ..reset()
          ..start();
        _refresh?.cancel();
        _refresh = Timer(idleRefresh, () => _queue(force: true));
        // Coordinates may have moved back while this RPC was in flight.
        if (syncRevision == _syncRevision && _same(_pending, _sent)) {
          _pending = null;
        }
      }
    } catch (_) {
      if (!_closed && generation == _generation) _lost(hub);
    } finally {
      if (generation == _generation) _sending = false;
    }
  }

  Future<void> _connect() async {
    if (_closed || _hub != null) return;
    final generation = ++_generation;
    HubConnection? hub;
    try {
      final token = await api.sessionToken();
      if (_closed || generation != _generation) return;
      if (token == null) throw StateError('SessionInvalid');
      final headers = MessageHeaders()
        ..setHeaderValue('X-Zipliner-Session', token);
      hub = _hub =
          hubFactory?.call() ??
          HubConnectionBuilder()
              .withUrl(
                '${api.baseUrl}/hubs/data',
                options: HttpConnectionOptions(
                  headers: headers,
                  transport: HttpTransportType.WebSockets,
                  requestTimeout: 15000,
                  logMessageContent: false,
                ),
              )
              .withAutomaticReconnect(retryDelays: const [])
              .build();
      final connection = hub;
      hub.onclose(({error}) {
        if (!_closed && identical(_hub, connection)) _lost(connection);
      });
      hub.on('DesktopViewerStateChanged', (args) {
        if (_closed ||
            generation != _generation ||
            args == null ||
            args.isEmpty) {
          return;
        }
        final event = args.first;
        if (event is! Map ||
            event['roleId'] != role.binding.roleId ||
            event['serverId'] != role.binding.serverId) {
          return;
        }
        if (_lease == null) {
          _earlyViewerState = event;
          return;
        }
        if (event['leaseId'] == _lease) _setViewers(event['viewers'] == true);
      });
      await hub
          .start()
          ?.then((_) async {
            if (_closed || generation != _generation) await _stop(connection);
          })
          .timeout(const Duration(seconds: 20));
      if (_closed || generation != _generation) return;
      await hub
          .invoke(
            'SendAuth',
            args: [
              {
                'roleId': role.binding.roleId,
                'serverId': role.binding.serverId,
                'gameAccountId': role.gameAccountId,
                'autoStartPosition': false,
              },
            ],
          )
          .timeout(const Duration(seconds: 20));
      if (_closed || generation != _generation) return;
      final ticket = await hub
          .invoke('BeginDesktopPositionPublisher')
          .timeout(const Duration(seconds: 20));
      if (_closed || generation != _generation) return;
      if (ticket is! Map ||
          ticket['leaseId'] is! String ||
          ticket['roleId'] != role.binding.roleId ||
          ticket['serverId'] != role.binding.serverId) {
        throw const FormatException('Invalid publisher scope');
      }
      _lease = ticket['leaseId'] as String;
      _sequence = 0;
      _attempt = 0;
      _sent = null;
      final early = _earlyViewerState;
      _earlyViewerState = null;
      _setViewers(
        early?['leaseId'] == _lease
            ? early!['viewers'] == true
            : ticket['viewers'] == true,
      );
    } catch (_) {
      if (!_closed && generation == _generation) _lost(hub);
    }
  }

  void _setViewers(bool viewers) {
    if (_viewers != viewers) _syncRevision++;
    final started = viewers && !_viewers;
    _viewers = viewers;
    if (!viewers) {
      _setSynced(false);
      _pending = null;
      _refresh?.cancel();
    } else if (started) {
      _queue(force: true);
    }
  }

  void _lost(HubConnection? hub) {
    if (_closed) return;
    _syncRevision++;
    _setSynced(false);
    _generation++;
    _hub = null;
    _lease = null;
    _earlyViewerState = null;
    _viewers = false;
    _sending = false;
    _pending = _sent = null;
    _refresh?.cancel();
    if (hub != null) unawaited(_stop(hub));
    _retry?.cancel();
    const delays = [3, 10, 30, 60];
    final delay = delays[_attempt.clamp(0, delays.length - 1)];
    _attempt++;
    AppLog.instance.warn('网站坐标上传连接中断，本机直连继续运行');
    _retry = Timer(Duration(seconds: delay), () => unawaited(_connect()));
  }

  /// Only a deliberate local stop may hand ownership back to the website.
  Future<void> close({bool handoff = false}) => _closing ??= _close(handoff);
  Future<void> _close(bool handoff) async {
    _closed = true;
    _syncRevision++;
    _setSynced(false);
    _generation++;
    _retry?.cancel();
    _refresh?.cancel();
    final hub = _hub;
    final lease = _lease;
    _hub = null;
    if (hub == null) return;
    if (handoff && lease != null && hub.state == HubConnectionState.Connected) {
      try {
        await hub
            .invoke('EndDesktopPosition', args: [lease])
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    await _stop(hub);
  }

  Future<void> _stop(HubConnection hub) async {
    try {
      await hub.stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
