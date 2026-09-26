import 'dart:collection';
import 'dart:math';

import '../skland/skland_models.dart';
import 'formatting.dart';
import 'zipline_exporter.dart';
import 'zipline_matcher.dart';

class DetectedZiplineStop {
  const DetectedZiplineStop({
    required this.order,
    required this.x,
    required this.y,
    required this.z,
    required this.direction,
    required this.distance,
    required this.heightOffset,
    this.connectToPrevious = true,
  });

  final int order;
  final int x;
  final double y;
  final int z;
  final String direction;
  final double distance;
  final double heightOffset;

  /// 与上一个识别到的滑索之间没有落地，导出时连成同一路线。
  final bool connectToPrevious;

  String get label => '($x,${formatNumber(y)},$z,$direction)';
}

/// 照搬 `ZiplineRealtimeDetector`：玩家停在滑索上（高度比标记高约 3.5 米且位置稳定）时记为一次识别。
class ZiplineRealtimeDetector {
  ZiplineRealtimeDetector(Iterable<ZiplineMark>? marks)
    : _candidates = [for (final mark in marks ?? const <ZiplineMark>[]) ...ZiplineCandidate.fromMark(mark)];

  static const standingHeightOffset = 3.5;
  static const standingHeightTolerance = 0.9;
  static const enterDistance = 4.0;
  static const leaveDistance = 10.0;
  static const _stableSampleCount = 3;
  static const _stableRadius = 1.2;
  static const _fastConfirmDistance = 1.0;
  static const _fastConfirmSpeed = 5.0;
  static const _groundEvidenceDistance = 6.0;
  static const _groundEvidenceHeightOffset = 1.0;

  // 候选对象只在构造时创建一次，后面用 identical 比较是否为同一个滑索。
  final List<ZiplineCandidate> _candidates;
  final Queue<PositionSnapshot> _recent = Queue();
  final List<DetectedZiplineStop> _stops = [];
  ZiplineCandidate? _lastDetected;
  int _detectedCount = 0;
  bool _breakBeforeNext = false;

  int get markCount => _candidates.length ~/ 4;

  List<DetectedZiplineStop> get detectedStops => List.unmodifiable(_stops);

  DetectedZiplineStop? update(PositionSnapshot? position) {
    if (position == null || _candidates.isEmpty) return null;

    _addRecent(position);
    final nearest = _findNearest(position);
    if (nearest == null) {
      if (_lastDetected != null && _lastDetected!.planarDistance(position) > leaveDistance) _lastDetected = null;
      return null;
    }

    _updateBreakEvidence(position, nearest);
    if (_lastDetected != null) {
      if (identical(nearest, _lastDetected) || _lastDetected!.planarDistance(position) <= leaveDistance) return null;
      _lastDetected = null;
    }

    if (!_isHeightMatched(position, nearest) || !_canConfirm(position, nearest)) return null;
    return _record(position, nearest);
  }

  /// 手动把当前位置最近的滑索加入结果。
  DetectedZiplineStop? addManual(PositionSnapshot? position) {
    if (position == null || _candidates.isEmpty) return null;
    final nearest = _findNearest(position);
    if (nearest == null) return null;
    _updateBreakEvidence(position, nearest);
    return _record(position, nearest);
  }

  DetectedZiplineStop _record(PositionSnapshot position, ZiplineCandidate candidate) {
    _detectedCount++;
    final stop = DetectedZiplineStop(
      order: _detectedCount,
      x: candidate.centerX.floor(),
      y: candidate.mark.y,
      z: candidate.centerZ.floor(),
      direction: candidate.direction,
      distance: candidate.planarDistance(position),
      heightOffset: position.y - candidate.mark.y,
      connectToPrevious: _detectedCount == 1 || !_breakBeforeNext,
    );
    _stops.add(stop);
    _breakBeforeNext = false;
    _lastDetected = candidate;
    return stop;
  }

  /// 去重后的编号列表，例如 `1. (10,5,20,北)`。
  String resultText() {
    final seen = <String>{};
    final lines = <String>[];
    for (final stop in _stops) {
      if (!seen.add('${stop.x},${stop.z}')) continue;
      lines.add('${lines.length + 1}. ${stop.label}');
    }
    return lines.join(platformNewLine);
  }

  String marksJson() => ZiplineCollectionExporter.exportMarksJson(_stops);

  String routesJson() => ZiplineCollectionExporter.exportRoutesJson(_stops);

  void _addRecent(PositionSnapshot position) {
    _recent.addLast(position);
    while (_recent.length > _stableSampleCount) {
      _recent.removeFirst();
    }
  }

  bool _isStable() {
    if (_recent.length < _stableSampleCount) return false;
    final first = _recent.first;
    for (final p in _recent) {
      final dx = p.x - first.x;
      final dz = p.z - first.z;
      if (sqrt(dx * dx + dz * dz) > _stableRadius) return false;
    }
    return true;
  }

  bool _canConfirm(PositionSnapshot position, ZiplineCandidate candidate) =>
      _isStable() ||
      (candidate.planarDistance(position) <= _fastConfirmDistance && _recentPlanarSpeed() <= _fastConfirmSpeed);

  /// 最近两次采样之间的水平位移（原实现未除以时间，保持一致）。
  double _recentPlanarSpeed() {
    if (_recent.length < 2) return double.maxFinite;
    final previous = _recent.elementAt(_recent.length - 2);
    final current = _recent.last;
    final dx = current.x - previous.x;
    final dz = current.z - previous.z;
    return sqrt(dx * dx + dz * dz);
  }

  ZiplineCandidate? _findNearest(PositionSnapshot position) {
    ZiplineCandidate? best;
    var bestDistance = double.maxFinite;
    for (final candidate in _candidates) {
      final distance = candidate.planarDistance(position);
      if (distance <= enterDistance && distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    return best;
  }

  static bool _isHeightMatched(PositionSnapshot position, ZiplineCandidate candidate) =>
      ((position.y - candidate.mark.y) - standingHeightOffset).abs() <= standingHeightTolerance;

  void _updateBreakEvidence(PositionSnapshot position, ZiplineCandidate candidate) {
    if (_detectedCount == 0 || identical(candidate, _lastDetected)) return;
    final heightOffset = position.y - candidate.mark.y;
    if (candidate.planarDistance(position) <= _groundEvidenceDistance && heightOffset < _groundEvidenceHeightOffset) {
      _breakBeforeNext = true;
    }
  }
}
