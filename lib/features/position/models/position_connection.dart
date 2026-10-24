enum PositionPhase {
  idle,
  connecting,
  connected,
  recovering,
  waitingForGame,
  failed,
  stopped,
}

enum PositionSource { direct, shared }

/// Transport lifecycle; coordinates and capture state live in PositionMonitor.
class PositionConnection {
  PositionPhase phase = PositionPhase.idle;
  PositionSource source = PositionSource.direct;
  bool get connected => phase == PositionPhase.connected;
  bool get connecting => phase == PositionPhase.connecting;
  bool get error =>
      phase == PositionPhase.failed || phase == PositionPhase.recovering;

  void transition(PositionPhase next) {
    phase = next;
  }
}
