import 'package:zipliner_client/shared/logging/app_log.dart';

/// Payload-free, bounded receive/dispatch measurements using a monotonic clock.
class PositionTiming {
  PositionTiming(this.source, {int Function()? now, void Function(String)? log})
    : _now = now ?? (() => _clock.elapsedMicroseconds),
      _log = log ?? AppLog.instance.info;
  static final _clock = Stopwatch()..start();
  String source;
  final int Function() _now;
  final void Function(String) _log;
  int? _last, _window;
  int? _setupStarted, _setupPrevious;

  /// One bounded line per setup phase; never includes credentials or payloads.
  void stage(String name) {
    final at = _now();
    _setupStarted ??= at;
    _log(
      '定位连接 source=$source stage=$name '
      'elapsed_ms=${(at - _setupStarted!) ~/ 1000} '
      'step_ms=${(at - (_setupPrevious ?? at)) ~/ 1000}',
    );
    _setupPrevious = at;
  }

  int _count = 0, _bursts = 0, _gaps = 0, _maxGap = 0, _maxDispatch = 0;
  int begin() {
    final at = _now();
    _window ??= at;
    final previous = _last;
    if (previous != null) {
      final gap = at - previous;
      if (gap > _maxGap) _maxGap = gap;
      if (gap < 50000) _bursts++;
      if (gap >= 3000000) _gaps++;
    }
    _last = at;
    _count++;
    return at;
  }

  void end(int received) {
    final cost = _now() - received;
    if (cost > _maxDispatch) _maxDispatch = cost;
    if (_now() - (_window ?? _now()) >= 15000000) flush();
  }

  void flush() {
    if (_count == 0) return;
    _log(
      '定位时序 source=$source frames=$_count gaps_3s=$_gaps '
      'burst_50ms=$_bursts max_gap_ms=${_maxGap ~/ 1000} '
      'max_dispatch_ms=${_maxDispatch ~/ 1000}',
    );
    _window = _now();
    _count = _bursts = _gaps = _maxGap = _maxDispatch = 0;
  }
}
