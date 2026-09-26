import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/position/capture_recorder.dart';
import 'package:zipliner_client/position/follow_placement.dart';
import 'package:zipliner_client/position/formatting.dart';
import 'package:zipliner_client/position/seam_analyzer.dart';
import 'package:zipliner_client/position/zipline_matcher.dart';
import 'package:zipliner_client/position/zipline_realtime_detector.dart';
import 'package:zipliner_client/skland/skland_models.dart';

void main() {
  group('ZiplineMatcher', () {
    const mark = ZiplineMark(10, 5.5, 20);

    test('四个候选中心对应四个方向', () {
      String dir(double x, double z) => ZiplineMatcher.findNearest(PositionSnapshot(x, 0, z), [mark]).direction!;
      expect(dir(11, 21), '北');
      expect(dir(9, 21), '西');
      expect(dir(9, 19), '南');
      expect(dir(11, 19), '东');
    });

    test('x/z 向下取整，y 保留标记高度；超过 3 米找不到', () {
      final result = ZiplineMatcher.findNearest(const PositionSnapshot(11.2, 99, 21.3), [
        const ZiplineMark(10.7, 5.5, 20.4),
      ]);
      expect((result.x, result.y, result.z), (11, 5.5, 21));
      expect(ZiplineMatcher.findNearest(const PositionSnapshot(20, 0, 30), [mark]).found, isFalse);
      expect(ZiplineMatcher.findNearest(const PositionSnapshot(20, 0, 30), [mark]).message, '未找到，刚放置的滑索可能需要过一小会才能查找到');
    });

    test('选择最近的候选', () {
      final result = ZiplineMatcher.findNearest(const PositionSnapshot(0, 0, 0), [
        const ZiplineMark(1.5, 1, 1.5),
        const ZiplineMark(-1.2, 2, -1.2),
      ]);
      expect(result.y, 2);
    });

    test('复制格式：元组与带引号方向的 JSON', () {
      const result = ZiplineLookupResult.found(11, 5.5, 21, '北');
      expect(result.toTupleText(), '(11,5.5,21,北)');
      expect(result.toJsonText(), '{"x":11,"y":5.5,"z":21,"d":"北"}');
      expect(const ZiplineLookupResult.found(1, 2, 3, '南').toJsonText(), '{"x":1,"y":2,"z":3,"d":"南"}');
    });
  });

  group('ZiplineRealtimeDetector', () {
    // 两个相距 20 米的滑索，玩家站在滑索上时高度比标记高 3.5 米。
    const a = ZiplineMark(0, 10, 0);
    const b = ZiplineMark(20, 10, 0);

    test('停在滑索上才识别（距中心 1 米内且移动很慢可快速确认），同一滑索不重复识别', () {
      final detector = ZiplineRealtimeDetector([a, b]);
      // 第一个采样没有历史速度，无法快速确认。
      expect(detector.update(const PositionSnapshot(1, 13.5, 1)), isNull);
      final first = detector.update(const PositionSnapshot(1.1, 13.5, 1));
      expect(first, isNotNull);
      expect(first!.label, '(1,10,1,北)');
      expect(detector.update(const PositionSnapshot(1, 13.5, 1)), isNull);

      for (var i = 0; i < 3; i++) {
        detector.update(PositionSnapshot(21, 13.5, 1 + i * 0.01));
      }
      expect(detector.detectedStops, hasLength(2));
      expect(detector.detectedStops.last.connectToPrevious, isTrue);
    });

    test('高度不匹配（在地面上）不识别，并让下一个识别断开路线', () {
      final detector = ZiplineRealtimeDetector([a, b]);
      detector.addManual(const PositionSnapshot(1, 13.5, 1));
      for (var i = 0; i < 3; i++) {
        expect(detector.update(const PositionSnapshot(21, 10.2, 1)), isNull);
      }
      for (var i = 0; i < 3; i++) {
        detector.update(const PositionSnapshot(21, 13.5, 1));
      }
      expect(detector.detectedStops.last.connectToPrevious, isFalse);
      expect(detector.routesJson(), '[{"name":"未命名路线","marks":["(1,1)"]},{"name":"未命名路线","marks":["(21,1)"]}]');
    });

    test('导出滑索与路线 JSON', () {
      final detector = ZiplineRealtimeDetector([a, b]);
      detector.addManual(const PositionSnapshot(1, 13.5, 1));
      detector.addManual(const PositionSnapshot(21, 13.5, 1));
      expect(
        detector.marksJson(),
        '[{"id":"(1,1)","name":"未命名滑索","connect":["(21,1)"],"h":10,"direction":"北"},'
        '{"id":"(21,1)","name":"未命名滑索","connect":["(1,1)"],"h":10,"direction":"北"}]',
      );
      expect(detector.routesJson(), '[{"name":"未命名路线","marks":["(1,1)","(21,1)"]}]');
      expect(detector.resultText(), '1. (1,10,1,北)${platformNewLine}2. (21,10,1,北)');
    });
  });

  group('formatting', () {
    test('坐标格式与原工具一致', () {
      expect(formatCoordinate(12.5), '  12.5    ');
      expect(formatCoordinate(3.0), '   3.     ');
      expect(formatCoordinate(-123.456789), '-123.45679');
    });

    test('数字格式', () {
      expect(formatNumber(5.0), '5');
      expect(formatNumber(5.25), '5.25');
      expect(formatUpTo8(1.0), '1');
      expect(formatUpTo8(0.123456789), '0.12345679');
      expect(maskToken('ABCDEFGHIJKL'), 'ABCD...IJKL');
      expect(maskToken('short'), '***');
    });

    test('采集时间戳与 C# "O" 格式一致', () {
      expect(
        PositionCaptureRecorder.roundTripUtc(DateTime.utc(2026, 5, 22, 4, 5, 6, 123, 456)),
        '2026-05-22T04:05:06.1234560+00:00',
      );
    });
  });

  test('采集记录写出 positions/marks/detections', () async {
    final base = await Directory.systemTemp.createTemp('zipliner_capture_');
    // Windows 上杀毒软件可能短暂占用新文件，清理失败不影响结果。
    addTearDown(() => base.delete(recursive: true).then<void>((_) {}, onError: (_) {}));
    final recorder = PositionCaptureRecorder(base.path)..start(DateTime(2026, 5, 22, 12, 30, 1));
    recorder.record(const PositionSnapshot(0, 0, 0), DateTime.utc(2026, 5, 22, 4, 30, 1));
    recorder.record(const PositionSnapshot(3, 0, 4), DateTime.utc(2026, 5, 22, 4, 30, 2));
    recorder.writeMarks([const ZiplineMark(1, 2, 3)]);
    recorder.stop();

    final dir = Directory(
      '${base.path}${Platform.pathSeparator}captures${Platform.pathSeparator}zipline-20260522-123001',
    );
    final positionsFile = File('${dir.path}${Platform.pathSeparator}positions.csv');
    const bom = [0xEF, 0xBB, 0xBF];
    expect(positionsFile.readAsBytesSync().take(3), bom);
    // Dart 解码 UTF-8 时会去掉 BOM。
    final lines = positionsFile.readAsStringSync().split(platformNewLine);
    expect(lines.first, startsWith('timestamp,label,event'));
    expect(lines[1], contains('"未标注","start"'));
    expect(lines[2], endsWith(',1,3,0,4,5,5,5,5'));
    final marksFile = File('${dir.path}${Platform.pathSeparator}marks.csv');
    expect(marksFile.readAsBytesSync().take(3), bom);
    expect(marksFile.readAsStringSync(), 'x,y,z${platformNewLine}1,2,3$platformNewLine');
  });

  group('FollowWindowPlacement', () {
    const game = Rect.fromLTWH(100, 100, 1000, 600);
    const window = Size(200, 100);

    test('各显示位置', () {
      expect(FollowWindowPlacement.calculate(game, window, FollowPosition.top, 0, 0), const Offset(500, 108));
      expect(FollowWindowPlacement.calculate(game, window, FollowPosition.bottomRight, 10, 20), const Offset(882, 572));
      expect(FollowWindowPlacement.calculate(game, window, FollowPosition.bottomLeft, 0, 0), const Offset(108, 562));
      expect(FollowWindowPlacement.calculate(game, window, FollowPosition.left, 0, -50), const Offset(108, 300));
    });
  });

  group('SeamMotionAnalyzer', () {
    final t0 = DateTime(2026, 1, 1, 12);
    List<SeamHeightSample> climb(int seconds, {double speed = 0.01}) => [
      for (var i = 0; i <= seconds; i++) SeamHeightSample(t0.add(Duration(seconds: i)), 0, i * speed, 0),
    ];

    test('匀速上升时按速度估算剩余时间', () {
      final estimate = SeamMotionAnalyzer.analyze(climb(10), 1.1);
      expect(estimate.message, '估算中');
      expect(estimate.estimatedSpeed, closeTo(0.01, 1e-9));
      expect(estimate.remainingTime!.inSeconds, 100);
    });

    test('到达目标高度与数据不足', () {
      expect(SeamMotionAnalyzer.analyze(climb(10), 0.1).message, '已到达目标高度');
      expect(SeamMotionAnalyzer.analyze([], 5).message, '等待更多数据');
      final still = [for (var i = 0; i < 5; i++) SeamHeightSample(t0.add(Duration(seconds: i)), 0, 1, 0)];
      expect(SeamMotionAnalyzer.analyze(still, 5).message, '等待更多运动数据');
    });

    test('报告：手动打点分段并计算平均速度', () {
      final samples = climb(10);
      samples[5] = SeamHeightSample(samples[5].timestamp, 0, samples[5].height, 0, manualBreak: true);
      final report = SeamMotionAnalyzer.buildReport(samples)!;
      expect(report.totalDistance, closeTo(0.1, 1e-9));
      expect(report.averageSpeed, closeTo(0.01, 1e-9));
      expect(report.segments.map((s) => s.reason), ['手动打点', null]);
    });
  });
}
