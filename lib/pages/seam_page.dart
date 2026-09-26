import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';

import '../core/services.dart';
import '../position/position_monitor.dart';
import '../position/seam_analyzer.dart';
import '../skland/skland_models.dart';
import '../ui/app_theme.dart';
import '../ui/section_body.dart';

/// “蹭缝”高度估算，对应原工具的 `SeamEstimateWindow`：
/// 填写目标高度后开始，3 秒倒计时结束开始记录高度，实时估算剩余时间，结束后给出分段报告。
class SeamPage extends StatefulWidget {
  const SeamPage({super.key});

  @override
  State<SeamPage> createState() => _SeamPageState();
}

class _SeamPageState extends State<SeamPage> {
  static const _tick = Duration(milliseconds: 250);
  static const _countdown = Duration(seconds: 3);
  static const _arrivedTolerance = 0.02;

  final _target = TextEditingController();
  Timer? _timer;
  PositionMonitor? _monitor;

  PositionSnapshot? _startPosition;
  DateTime? _countdownEnd;
  double? _targetHeight;
  List<SeamHeightSample>? _samples;
  bool _running = false;

  String? _countdownText;
  String? _estimateText;
  String? _status;
  String? _report;

  bool get _counting => _countdownEnd != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _monitor ??= AppServices.of(context).monitor;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _target.dispose();
    super.dispose();
  }

  double? _parseTarget() => double.tryParse(_target.text.trim().replaceAll('，', '.').replaceAll(',', '.'));

  void _start() {
    final position = _monitor!.position;
    if (position == null) return setState(() => _status = '等待 websocket 坐标数据');
    if (_target.text.trim().isEmpty) return setState(() => _status = '请先填写目标高度');
    final target = _parseTarget();
    if (target == null) return setState(() => _status = '目标高度格式不正确');

    setState(() {
      _startPosition = position;
      _targetHeight = target;
      _countdownEnd = DateTime.now().add(_countdown);
      _countdownText = '倒计时：3 秒';
      _estimateText = null;
      _report = null;
      _status =
          '起始高度 ${_formatPosition(position.y, position.x, position.z)}，目标高度 ${_formatHeight(target)}，'
          '高度差 ${_formatHeight((target - position.y).abs())}';
    });
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _onTick());
  }

  void _onTick() {
    if (!mounted) return;
    final now = DateTime.now();
    final end = _countdownEnd;
    if (end != null) {
      final remaining = end.difference(now);
      if (remaining > Duration.zero) {
        setState(() => _countdownText = '倒计时：${(remaining.inMilliseconds / 1000).ceil()} 秒');
        return;
      }
      final start = _startPosition!;
      setState(() {
        _countdownEnd = null;
        _countdownText = null;
        _samples = [SeamHeightSample(now, start.x, start.y, start.z)];
        _running = true;
        _status = '运行中';
      });
      return;
    }
    if (!_running) return;
    final position = _monitor!.position;
    if (position == null) return;
    final samples = _samples!..add(SeamHeightSample(now, position.x, position.y, position.z));
    final estimate = SeamMotionAnalyzer.analyze(samples, _targetHeight!);
    setState(() => _estimateText = _formatEstimate(estimate));
    if ((position.y - _targetHeight!).abs() <= _arrivedTolerance) _finish('已到达目标高度');
  }

  void _mark() {
    final position = _monitor!.position;
    if (!_running || position == null) return;
    _samples!.add(SeamHeightSample(DateTime.now(), position.x, position.y, position.z, manualBreak: true));
    setState(() => _status = '已手动打点');
  }

  void _finish(String reason) {
    _timer?.cancel();
    final samples = _samples;
    final position = _monitor!.position;
    if (samples != null && position != null) {
      final now = DateTime.now();
      final last = samples.isEmpty ? null : samples.last;
      final duplicate =
          last != null &&
          last.timestamp == now &&
          (last.x - position.x).abs() < 1e-6 &&
          (last.height - position.y).abs() < 1e-6 &&
          (last.z - position.z).abs() < 1e-6;
      if (!duplicate) samples.add(SeamHeightSample(now, position.x, position.y, position.z));
    }
    setState(() {
      _running = false;
      _countdownEnd = null;
      _countdownText = null;
      _status = reason;
      _report = samples == null ? '没有生成报告。' : _reportText(SeamMotionAnalyzer.buildReport(samples));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = AppFonts.monoStyle(theme.textTheme.bodyMedium);
    return ListenableBuilder(
      listenable: _monitor!,
      builder: (context, _) {
        final position = _monitor!.position;
        final live = position != null;
        final idle = !_counting && !_running;
        return TfListView(
          children: [
            if (!live && idle)
              const TfBanner(type: TfToastType.info, message: '需要先在“坐标”页连接成功并收到坐标，才能开始估算。填写目标高度后点“开始”，站着不动 3 秒后开始记录。'),
            TfSection(
              title: '高度',
              children: [
                TfListTile(
                  leading: const Icon(Icons.height),
                  title: const Text('当前高度（Y）'),
                  subtitle: Text(
                    position == null ? '等待 websocket 坐标' : _formatPosition(position.y, position.x, position.z),
                    style: AppFonts.monoStyle(theme.textTheme.headlineSmall),
                  ),
                ),
                SectionBody(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      TfTextField(
                        controller: _target,
                        enabled: idle,
                        placeholder: '目标高度（Y）',
                        prefixIcon: Icons.flag_outlined,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        onSubmitted: (_) => live && idle ? _start() : null,
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TfButton(label: '开始', icon: Icons.play_arrow, onPressed: live && idle ? _start : null),
                          TfButton.secondary(
                            label: '结束',
                            icon: Icons.stop,
                            onPressed: idle ? null : () => _finish('手动结束'),
                          ),
                          TfButton.secondary(
                            label: '打点',
                            icon: Icons.push_pin_outlined,
                            onPressed: live && _running ? _mark : null,
                          ),
                        ],
                      ),
                      if (_countdownText != null) Text(_countdownText!, style: theme.textTheme.titleMedium),
                      if (_estimateText != null) Text(_estimateText!, style: theme.textTheme.bodyLarge),
                      if (_status != null) Text(_status!, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            TfSection(
              title: '报告',
              children: [SectionBody(child: SelectableText(_report ?? '开始后会在这里显示最终报告。', style: mono))],
            ),
          ],
        );
      },
    );
  }
}

String _formatHeight(double v) => v.toStringAsFixed(3);

/// C# `"0.###"`：最多 3 位小数。
String _formatCoordinate(double v) {
  var text = v.toStringAsFixed(3);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return text == '-0' ? '0' : text;
}

String _formatDistance(double v) => v.toStringAsFixed(4);

String _formatPosition(double h, double x, double z) =>
    '${_formatHeight(h)} (${_formatCoordinate(x)},${_formatCoordinate(z)})';

String _two(int v) => v.toString().padLeft(2, '0');

String _time(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';

String _dateTime(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} ${_time(t)}';

String _duration(Duration d) =>
    '${_two(d.inHours.remainder(24))}:${_two(d.inMinutes.remainder(60))}:${_two(d.inSeconds.remainder(60))}';

String _formatEstimate(SeamMotionEstimate estimate) {
  final remaining = estimate.remainingTime;
  if (remaining == null) return '还没有足够数据用于预估。';
  return '还剩下 ${_formatDistance(estimate.remainingHeight)} 米，预计还要 ${remaining.inMinutes} 分 '
      '${remaining.inSeconds.remainder(60)} 秒，当前预估速度 ${_formatDistance(estimate.estimatedSpeed)} 米/秒';
}

String _reportText(SeamMotionReport? report) {
  if (report == null) return '没有生成报告。';
  final lines = [
    '起始高度：${_formatPosition(report.start.height, report.start.x, report.start.z)}',
    '起始时间：${_dateTime(report.start.timestamp)}',
    '结束高度：${_formatPosition(report.end.height, report.end.x, report.end.z)}',
    '结束时间：${_dateTime(report.end.timestamp)}',
    '总高度：${_formatDistance(report.totalDistance)}',
    '总时间：${_duration(report.totalDuration)}',
    '平均速度：${_formatDistance(report.averageSpeed)} 米/秒',
    '',
    '分段：',
  ];
  if (report.segments.isEmpty) {
    lines.add('  无有效移动分段');
  } else {
    for (final (i, s) in report.segments.indexed) {
      lines.add(
        '  ${i + 1}. ${_formatPosition(s.startHeight, s.startX, s.startZ)} -> ${_formatPosition(s.endHeight, s.endX, s.endZ)}'
        ' | ${_time(s.startTime)} - ${_time(s.endTime)} | ${_formatDistance(s.speed)} 米/秒'
        '${s.reason == null ? '' : ' | ${s.reason}'}',
      );
    }
  }
  return lines.join('\n');
}
