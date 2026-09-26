import 'dart:math';

class SeamHeightSample {
  const SeamHeightSample(this.timestamp, this.x, this.height, this.z, {this.manualBreak = false});

  final DateTime timestamp;
  final double x;
  final double height;
  final double z;

  /// 用户按了“打点”，报告在此处强制分段。
  final bool manualBreak;
}

class SeamMotionSegment {
  SeamMotionSegment(
    this.startTime,
    this.endTime,
    this.startX,
    this.startHeight,
    this.startZ,
    this.endX,
    this.endHeight,
    this.endZ,
    this.reason,
  ) : distance = (endHeight - startHeight).abs(),
      duration = endTime.difference(startTime);

  final DateTime startTime;
  final DateTime endTime;
  final double startX;
  final double startHeight;
  final double startZ;
  final double endX;
  final double endHeight;
  final double endZ;
  final String? reason;
  final double distance;
  final Duration duration;

  double get seconds => duration.inMicroseconds / 1e6;

  double get speed => seconds > 0 ? distance / seconds : 0;
}

class SeamMotionEstimate {
  const SeamMotionEstimate({
    required this.currentHeight,
    required this.targetHeight,
    required this.remainingHeight,
    required this.estimatedSpeed,
    required this.remainingTime,
    required this.message,
    required this.segments,
  });

  final double currentHeight;
  final double targetHeight;
  final double remainingHeight;
  final double estimatedSpeed;
  final Duration? remainingTime;
  final String message;
  final List<SeamMotionSegment> segments;
}

class SeamMotionReport {
  const SeamMotionReport({
    required this.start,
    required this.end,
    required this.totalDistance,
    required this.totalDuration,
    required this.averageSpeed,
    required this.segments,
  });

  final SeamHeightSample start;
  final SeamHeightSample end;
  final double totalDistance;
  final Duration totalDuration;
  final double averageSpeed;
  final List<SeamMotionSegment> segments;
}

/// 照搬 `SeamMotionAnalyzer`：根据高度采样估算“蹭缝”到目标高度还需要多久。
abstract final class SeamMotionAnalyzer {
  static const _movingSpeed = 0.0015;
  static const _stoppingSpeed = 0.0007;
  static const _stopStreakToClose = 3;
  static const _minSegmentDistance = 0.003;
  static const _minSegmentSeconds = 1.0;
  static const _xzRangeBreak = 0.45;
  static const _xzBreakMinSamples = 3;

  static SeamMotionEstimate analyze(List<SeamHeightSample> samples, double targetHeight) {
    if (samples.isEmpty) {
      return SeamMotionEstimate(
        currentHeight: 0,
        targetHeight: targetHeight,
        remainingHeight: targetHeight.abs(),
        estimatedSpeed: 0,
        remainingTime: null,
        message: '等待更多数据',
        segments: const [],
      );
    }

    final report = _reportSegments(samples);
    final usable = _movingSegments(samples)
        .where((s) => s.distance >= _minSegmentDistance && s.seconds >= _minSegmentSeconds)
        .toList();
    final current = samples.last.height;
    final remaining = (targetHeight - current).abs();
    if (remaining <= 0.000001) {
      return SeamMotionEstimate(
        currentHeight: current,
        targetHeight: targetHeight,
        remainingHeight: 0,
        estimatedSpeed: 0,
        remainingTime: Duration.zero,
        message: '已到达目标高度',
        segments: report,
      );
    }

    final speed = _combine(_recentWindowSpeed(samples), _recentSegmentSpeed(usable), _overallSpeed(usable));
    if (speed <= 0) {
      return SeamMotionEstimate(
        currentHeight: current,
        targetHeight: targetHeight,
        remainingHeight: remaining,
        estimatedSpeed: 0,
        remainingTime: null,
        message: '等待更多运动数据',
        segments: report,
      );
    }
    return SeamMotionEstimate(
      currentHeight: current,
      targetHeight: targetHeight,
      remainingHeight: remaining,
      estimatedSpeed: speed,
      remainingTime: Duration(microseconds: (remaining / speed * 1e6).round()),
      message: '估算中',
      segments: report,
    );
  }

  static SeamMotionReport? buildReport(List<SeamHeightSample> samples) {
    if (samples.isEmpty) return null;
    final first = samples.first;
    final last = samples.last;
    final duration = last.timestamp.difference(first.timestamp);
    final distance = (last.height - first.height).abs();
    final seconds = duration.inMicroseconds / 1e6;
    return SeamMotionReport(
      start: first,
      end: last,
      totalDistance: distance,
      totalDuration: duration,
      averageSpeed: seconds > 0 ? distance / seconds : 0,
      segments: _reportSegments(samples),
    );
  }

  static List<SeamMotionSegment> _reportSegments(List<SeamHeightSample> samples) {
    final segments = <SeamMotionSegment>[];
    if (samples.length < 2) return segments;
    var start = 0;
    for (var i = 1; i < samples.length; i++) {
      // 报告分段首尾相接，避免丢掉起点、暂停段或终点。
      if (samples[i].manualBreak) {
        _addSegment(samples, start, i, '手动打点', segments);
        start = i;
        continue;
      }
      if (i - start >= _xzBreakMinSamples && _hasXzRangeBreak(samples, start, i)) {
        _addSegment(samples, start, i, 'XZ 波动', segments);
        start = i;
      }
    }
    _addSegment(samples, start, samples.length - 1, null, segments);
    return segments;
  }

  static bool _hasXzRangeBreak(List<SeamHeightSample> samples, int start, int end) {
    var minX = samples[start].x, maxX = samples[start].x;
    var minZ = samples[start].z, maxZ = samples[start].z;
    for (var i = start + 1; i <= end; i++) {
      minX = min(minX, samples[i].x);
      maxX = max(maxX, samples[i].x);
      minZ = min(minZ, samples[i].z);
      maxZ = max(maxZ, samples[i].z);
    }
    final dx = maxX - minX, dz = maxZ - minZ;
    return sqrt(dx * dx + dz * dz) >= _xzRangeBreak;
  }

  static void _addSegment(
    List<SeamHeightSample> samples,
    int start,
    int end,
    String? reason,
    List<SeamMotionSegment> segments,
  ) {
    if (start < 0 || end <= start || end >= samples.length) return;
    segments.add(_segment(samples[start], samples[end], reason));
  }

  static SeamMotionSegment _segment(SeamHeightSample a, SeamHeightSample b, String? reason) =>
      SeamMotionSegment(a.timestamp, b.timestamp, a.x, a.height, a.z, b.x, b.height, b.z, reason);

  static List<SeamMotionSegment> _movingSegments(List<SeamHeightSample> samples) {
    final segments = <SeamMotionSegment>[];
    if (samples.length < 2) return segments;
    var start = -1;
    var stopStreak = 0;
    for (var i = 1; i < samples.length; i++) {
      final seconds = samples[i].timestamp.difference(samples[i - 1].timestamp).inMicroseconds / 1e6;
      if (seconds <= 0) continue;
      final speed = (samples[i].height - samples[i - 1].height).abs() / seconds;
      final moving = speed >= _movingSpeed;
      if (start < 0) {
        if (moving) start = i - 1;
        stopStreak = 0;
        continue;
      }
      if (moving) {
        stopStreak = 0;
        continue;
      }
      if (speed <= _stoppingSpeed) {
        stopStreak++;
        if (stopStreak >= _stopStreakToClose) {
          _addMoving(samples, start, i - stopStreak, segments);
          start = -1;
          stopStreak = 0;
        }
      } else {
        stopStreak = 0;
      }
    }
    if (start >= 0) _addMoving(samples, start, samples.length - 1, segments);
    return segments;
  }

  static void _addMoving(List<SeamHeightSample> samples, int start, int end, List<SeamMotionSegment> segments) {
    if (start < 0 || end <= start || end >= samples.length) return;
    final segment = _segment(samples[start], samples[end], null);
    if (segment.distance < _minSegmentDistance || segment.seconds < _minSegmentSeconds) return;
    segments.add(segment);
  }

  static double _recentWindowSpeed(List<SeamHeightSample> samples) {
    if (samples.length < 2) return 0;
    final start = samples[max(0, samples.length - 5)];
    final end = samples.last;
    final seconds = end.timestamp.difference(start.timestamp).inMicroseconds / 1e6;
    if (seconds <= 0) return 0;
    final speed = (end.height - start.height).abs() / seconds;
    return speed >= _movingSpeed ? speed : 0;
  }

  static double _recentSegmentSpeed(List<SeamMotionSegment> segments) {
    if (segments.isEmpty) return 0;
    final start = max(0, segments.length - 3);
    var distance = 0.0, time = 0.0;
    for (var i = start; i < segments.length; i++) {
      final weight = i - start + 1;
      distance += segments[i].distance * weight;
      time += segments[i].seconds * weight;
    }
    return time > 0 ? distance / time : 0;
  }

  static double _overallSpeed(List<SeamMotionSegment> segments) {
    var distance = 0.0, time = 0.0;
    for (final s in segments) {
      distance += s.distance;
      time += s.seconds;
    }
    return time > 0 ? distance / time : 0;
  }

  static double _combine(double active, double recent, double overall) {
    if (active > 0 && recent > 0 && overall > 0) return active * 0.5 + recent * 0.3 + overall * 0.2;
    if (active > 0 && recent > 0) return active * 0.6 + recent * 0.4;
    if (recent > 0 && overall > 0) return recent * 0.7 + overall * 0.3;
    if (active > 0) return active;
    if (recent > 0) return recent;
    return overall;
  }
}
