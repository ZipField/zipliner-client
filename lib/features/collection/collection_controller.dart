import 'dart:async';

import 'package:zipliner_client/integrations/skland/skland_models.dart';

import 'capture_recorder.dart';
import 'detected_zipline_stop.dart';
import 'zipline_matcher.dart';
import 'zipline_realtime_detector.dart';

/// Snapshot of connection identity used to reject late capture responses.
class CollectionContext {
  const CollectionContext({
    required this.revision,
    this.role,
    this.mapId,
    this.position,
  });
  final int revision;
  final RoleSession? role;
  final String? mapId;
  final PositionSnapshot? position;
}

/// Owns collection, recognition and recording; it doesn't open position connections.
class CollectionController {
  CollectionController({
    required this._readContext,
    required this._loadMarks,
    required this._captureDirectory,
    required this._setWarning,
    required this._onChanged,
    this._recordCapture = false,
  });

  final CollectionContext Function() _readContext;
  final Future<List<ZiplineMark>> Function(RoleSession role, String map)
  _loadMarks;
  final Future<String> Function() _captureDirectory;
  final void Function(String? warning) _setWarning;
  final void Function() _onChanged;
  void Function(DetectedZiplineStop stop)? onDetection;

  void clearMap({bool resetAttempt = false}) {
    captureMarks = null;
    detector = null;
    if (resetAttempt) _marksAttemptKey = null;
  }

  // ---- 滑索采集 ----

  bool isCapturing = false;
  bool isLoadingMarks = false;
  List<ZiplineMark>? captureMarks;
  ZiplineRealtimeDetector? detector;
  ZiplineLookupResult? lookupResult;
  String? manualResultText;
  PositionCaptureRecorder? _recorder;
  String? _marksAttemptKey;
  bool _recordCapture;
  set warning(String? value) => _setWarning(value);

  bool get recordCapture => _recordCapture;

  set recordCapture(bool value) {
    _recordCapture = value;
    _notify();
  }

  bool get hasDetections => detector?.detectedStops.isNotEmpty ?? false;

  String get captureStatusText {
    final recorder = _recorder;
    if (isCapturing) {
      return recorder != null && recorder.isRecording
          ? '采集中：样本 ${recorder.sampleCount}，目录 ${recorder.currentSessionDirectory}。停在滑索上等待识别，也可以手动获取当前滑索。'
          : '采集中：未记录文件。停在滑索上等待识别，也可以手动获取当前滑索。';
    }
    return _recordCapture
        ? '未采集。开始采集后会记录 positions、marks、detections 文件。'
        : '未采集。当前不会记录文件，只保留本次识别结果用于复制。';
  }

  String? get realtimeText {
    if (!isCapturing && !hasDetections) return null;
    final d = detector;
    if (d == null) return '实时识别：等待滑索数据';
    return '实时识别：${d.detectedStops.length} 个\n${d.resultText()}';
  }

  Future<void> startCapture() async {
    isCapturing = true;
    if (_recordCapture) {
      (_recorder ??= PositionCaptureRecorder(
        await _captureDirectory(),
      )).start(DateTime.now());
    } else {
      _recorder?.stop();
    }
    captureMarks = null;
    detector = null;
    lookupResult = null;
    manualResultText = null;
    _marksAttemptKey = null;
    warning = '已开始采集，正在获取当前地图滑索数据...';
    _notify();
    await _loadCaptureMarks();
  }

  void stopCapture() {
    isCapturing = false;
    _recorder?.stop();
    warning = '已停止采集';
    _notify();
  }

  bool get _hasCapturePrerequisites =>
      _readContext().mapId != null && _readContext().role != null;

  Future<void> _loadCaptureMarks() async {
    final context = _readContext();
    final run = context.revision;
    final role = context.role;
    final map = context.mapId;
    if (map == null || role == null) {
      warning = '已开始采集；等待地图、登录和角色信息后再获取滑索数据';
      _notify();
      return;
    }
    _marksAttemptKey = '${role.key}|$map';
    isLoadingMarks = true;
    _notify();
    try {
      final marks = await _loadMarks(role, map);
      if (run != _readContext().revision) return;
      captureMarks = marks;
      if (_recorder?.isRecording ?? false) _recorder!.writeMarks(marks);
      detector = ZiplineRealtimeDetector(marks);
      warning = '已获取滑索数据：${marks.length} 个，停在滑索上等待识别';
    } on SklandException catch (e) {
      warning = e.message;
    } catch (_) {
      warning = '获取采集用滑索数据失败';
    } finally {
      if (run == _readContext().revision) {
        isLoadingMarks = false;
        _notify();
      }
    }
  }

  void acceptPosition(PositionSnapshot p) {
    final context = _readContext();
    final recorder = _recorder;
    if (recorder != null && recorder.isRecording) {
      recorder.record(p, DateTime.now());
    }
    if (!isCapturing) return;

    final d = detector;
    if (d == null) {
      final key = '${context.role?.key}|${context.mapId}';
      if (!isLoadingMarks &&
          _hasCapturePrerequisites &&
          _marksAttemptKey != key) {
        unawaited(_loadCaptureMarks());
      }
      return;
    }
    final stop = d.update(p);
    if (stop != null) _reportDetection(stop);
  }

  void _reportDetection(DetectedZiplineStop stop) {
    final recorder = _recorder;
    if (recorder != null && recorder.isRecording) {
      recorder.writeDetection(stop, DateTime.now());
    }
    warning = '已识别第 ${stop.order} 个滑索：${stop.label}';
    lastDetection = stop;
    lastDetectionAt = DateTime.now();
    onDetection?.call(stop);
  }

  DetectedZiplineStop? lastDetection;
  DateTime? lastDetectionAt;

  /// 手动查找当前位置 3 米内的滑索，并加入采集结果。
  Future<void> manualDetect() async {
    final context = _readContext();
    final run = context.revision;
    final p = context.position;
    if (p == null) return _setManual('缺少当前位置，连接成功并获取坐标后再试');
    if (context.mapId == null) return _setManual('缺少当前地图 ID，等待坐标同步后再试');
    final role = context.role;
    if (role == null) return _setManual('缺少登录或角色信息，连接成功后再试');

    _setManual('正在获取滑索坐标...');
    try {
      final marks = captureMarks ?? await _loadMarks(role, context.mapId!);
      if (run != _readContext().revision) return;
      captureMarks = marks;
      final result = ZiplineMatcher.findNearest(p, marks);
      lookupResult = result;
      manualResultText = result.found ? result.toTupleText() : result.message;
      if (result.found) {
        final stop = (detector ??= ZiplineRealtimeDetector(marks)).addManual(p);
        if (stop != null) _reportDetection(stop);
      }
      _notify();
    } on SklandException catch (e) {
      _setManual(e.message);
    } catch (_) {
      _setManual('获取滑索坐标失败');
    }
  }

  void _setManual(String text) {
    manualResultText = text;
    _notify();
  }

  void _notify() => _onChanged();

  void dispose() => _recorder?.stop();
}
