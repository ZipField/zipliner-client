import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/features/position/models/position_connection.dart';
import 'package:zipliner_client/features/position/application/position_timing.dart';

void main() {
  test(
    'shared recovery cannot be connected and connecting at the same time',
    () {
      final state = PositionConnection()..source = PositionSource.shared;
      state.transition(PositionPhase.connecting);
      expect(state.connecting, isTrue);
      expect(state.connected, isFalse);
      state.transition(PositionPhase.connected);
      expect(state.connected, isTrue);
      expect(state.connecting, isFalse);
      state.transition(PositionPhase.recovering);
      expect(state.connected, isFalse);
      expect(state.error, isTrue);
      state.transition(PositionPhase.stopped);
      expect(state.error, isFalse);
      expect(state.connecting, isFalse);
    },
  );

  test('timing distinguishes a receive gap, burst and local processing stall without payloads', () {
    var now = 0;
    final logs = <String>[];
    final timing = PositionTiming('shared', now: () => now, log: logs.add);
    timing.end(timing.begin());
    now = 4000000;
    final at = timing.begin();
    now += 120000;
    timing.end(at);
    now += 1000;
    timing.end(timing.begin());
    now += 1000;
    timing.end(timing.begin());
    timing.flush();
    expect(logs.single, contains('frames=4'));
    expect(logs.single, contains('gaps_3s=1'));
    expect(logs.single, contains('burst_50ms=1'));
    expect(logs.single, contains('max_dispatch_ms=120'));
    timing.flush();
    expect(logs, hasLength(1));
  });
}
