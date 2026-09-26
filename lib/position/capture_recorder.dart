import 'dart:io';
import 'dart:math';

import '../skland/skland_models.dart';
import 'formatting.dart';
import 'zipline_realtime_detector.dart';

/// 照搬 `PositionCaptureRecorder`：把采集过程写成 CSV（UTF-8 带 BOM），便于离线分析。
///
/// 目录结构：`<baseDirectory>/captures/zipline-yyyyMMdd-HHmmss/{positions,detections,marks}.csv`。
class PositionCaptureRecorder {
  PositionCaptureRecorder(String baseDirectory) : _captureDirectory = '$baseDirectory${Platform.pathSeparator}captures';

  static const _header = 'timestamp,label,event,x,y,z,dtSeconds,dx,dy,dz,planarDistance,distance3d,planarSpeed,speed3d';
  static const _bom = '\uFEFF';

  final String _captureDirectory;
  RandomAccessFile? _writer;
  RandomAccessFile? _detectionWriter;
  PositionSnapshot? _previousPosition;
  DateTime? _previousTimestamp;
  String? _pendingEvent;

  bool isRecording = false;
  String currentLabel = '未标注';
  String? currentSessionDirectory;
  int sampleCount = 0;

  void start(DateTime timestamp) {
    stop();
    final name = 'zipline-${_compactLocal(timestamp.toLocal())}';
    final dir = Directory('$_captureDirectory${Platform.pathSeparator}$name')..createSync(recursive: true);
    currentSessionDirectory = dir.path;
    _writer = _open('positions.csv')..writeStringSync('$_bom$_header$platformNewLine');
    _detectionWriter = _open('detections.csv')
      ..writeStringSync(
        '${_bom}timestamp,order,x,y,z,direction,distance,heightOffset,connectToPrevious$platformNewLine',
      );
    isRecording = true;
    sampleCount = 0;
    _previousPosition = null;
    _previousTimestamp = null;
    _pendingEvent = 'start';
  }

  void stop() {
    final writer = _writer;
    final detectionWriter = _detectionWriter;
    _writer = null;
    _detectionWriter = null;
    isRecording = false;
    _previousPosition = null;
    _previousTimestamp = null;
    _pendingEvent = null;
    writer?.closeSync();
    detectionWriter?.closeSync();
  }

  void record(PositionSnapshot? position, DateTime timestamp) {
    final writer = _writer;
    if (!isRecording || position == null || writer == null) return;

    var dt = 0.0, dx = 0.0, dy = 0.0, dz = 0.0;
    final previous = _previousPosition;
    if (previous != null && _previousTimestamp != null) {
      dt = max(0, timestamp.difference(_previousTimestamp!).inMicroseconds / 1e6);
      dx = position.x - previous.x;
      dy = position.y - previous.y;
      dz = position.z - previous.z;
    }
    final planar = sqrt(dx * dx + dz * dz);
    final distance3d = sqrt(dx * dx + dy * dy + dz * dz);
    writer.writeStringSync(
      [
        _csv(roundTripUtc(timestamp)),
        _csv(currentLabel),
        _csv(_pendingEvent ?? ''),
        for (final v in [
          position.x,
          position.y,
          position.z,
          dt,
          dx,
          dy,
          dz,
          planar,
          distance3d,
          dt > 0 ? planar / dt : 0.0,
          dt > 0 ? distance3d / dt : 0.0,
        ])
          formatUpTo8(v),
      ].join(','),
    );
    writer.writeStringSync(platformNewLine);
    writer.flushSync();

    sampleCount++;
    _previousPosition = position;
    _previousTimestamp = timestamp;
    _pendingEvent = null;
  }

  void writeMarks(Iterable<ZiplineMark> marks) {
    final dir = currentSessionDirectory;
    if (dir == null) return;
    final buffer = StringBuffer('${_bom}x,y,z$platformNewLine');
    for (final mark in marks) {
      buffer.write('${formatUpTo8(mark.x)},${formatUpTo8(mark.y)},${formatUpTo8(mark.z)}$platformNewLine');
    }
    File('$dir${Platform.pathSeparator}marks.csv').writeAsStringSync(buffer.toString());
  }

  void writeDetection(DetectedZiplineStop stop, DateTime timestamp) {
    final writer = _detectionWriter;
    if (!isRecording || writer == null) return;
    writer.writeStringSync(
      [
        _csv(roundTripUtc(timestamp)),
        stop.order.toString(),
        stop.x.toString(),
        formatUpTo8(stop.y),
        stop.z.toString(),
        _csv(stop.direction),
        formatUpTo8(stop.distance),
        formatUpTo8(stop.heightOffset),
        stop.connectToPrevious ? 'true' : 'false',
      ].join(','),
    );
    writer.writeStringSync(platformNewLine);
    writer.flushSync();
  }

  RandomAccessFile _open(String fileName) =>
      File('${currentSessionDirectory!}${Platform.pathSeparator}$fileName').openSync(mode: FileMode.write);

  static String _csv(String value) => '"${value.replaceAll('"', '""')}"';

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _compactLocal(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  /// C# `DateTimeOffset.ToString("O")` 的 UTC 形式：`2026-05-22T04:05:06.1234567+00:00`。
  static String roundTripUtc(DateTime timestamp) {
    final t = timestamp.toUtc();
    final ticks = (t.millisecond * 1000 + t.microsecond) * 10;
    return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}T'
        '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${ticks.toString().padLeft(7, '0')}+00:00';
  }
}
