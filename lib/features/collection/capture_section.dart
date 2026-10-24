import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/app/app_preferences.dart';
import 'package:zipliner_client/app/app_theme.dart';
import 'package:zipliner_client/shared/widgets/section_body.dart';

import 'package:zipliner_client/features/position/presentation/position_ui_actions.dart';

class CaptureSection extends StatelessWidget {
  const CaptureSection({super.key, required this.monitor, required this.prefs});

  final PositionMonitor monitor;
  final TfPreferencesController prefs;

  Future<void> _start(BuildContext context) async {
    if (monitor.collection.hasDetections) {
      final ok = await showTfConfirm(
        context,
        title: '确认开始采集',
        message: '开始新的采集会清除当前已识别的滑索数据，是否继续？',
        destructive: true,
      );
      if (!ok) return;
    }
    await monitor.collection.startCapture();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lookup = monitor.collection.lookupResult;
    final detector = monitor.collection.detector;
    final realtime = monitor.collection.realtimeText;
    final mono = AppFonts.monoStyle(theme.textTheme.bodyMedium);
    return TfSection(
      title: '数据采集',
      children: [
        TfListTile(
          leading: const Icon(Icons.save_alt_outlined),
          title: const Text('记录采集数据到文件'),
          trailing: TfSwitch(
            value: monitor.collection.recordCapture,
            onChanged: monitor.collection.isCapturing
                ? null
                : (value) {
                    monitor.collection.recordCapture = value;
                    prefs.set(AppPreferences.recordCapture, value);
                  },
          ),
        ),
        SectionBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                monitor.collection.captureStatusText,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TfButton(
                    label: '开始采集',
                    icon: Icons.play_arrow,
                    onPressed: monitor.collection.isCapturing
                        ? null
                        : () => _start(context),
                  ),
                  TfButton.secondary(
                    label: '停止采集',
                    icon: Icons.stop,
                    onPressed: monitor.collection.isCapturing
                        ? monitor.collection.stopCapture
                        : null,
                  ),
                  TfButton.secondary(
                    label: '手动获取当前滑索',
                    icon: Icons.ads_click,
                    loading: monitor.collection.isLoadingMarks,
                    onPressed:
                        monitor.position != null &&
                            !monitor.collection.isLoadingMarks
                        ? monitor.collection.manualDetect
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (monitor.collection.manualResultText != null)
          TfListTile(
            leading: const Icon(Icons.place_outlined),
            title: const Text('当前滑索'),
            subtitle: SelectableText(
              monitor.collection.manualResultText!,
              style: mono,
            ),
          ),
        if (realtime != null)
          SectionBody(child: SelectableText(realtime, style: mono)),
        SectionBody(
          vertical: 8,
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              TfButton.text(
                label: '复制滑索 JSON',
                icon: Icons.copy,
                onPressed: detector != null && monitor.collection.hasDetections
                    ? () => copyPositionText(context, detector.marksJson())
                    : null,
              ),
              TfButton.text(
                label: '复制路线集合',
                icon: Icons.route_outlined,
                onPressed: detector != null && monitor.collection.hasDetections
                    ? () => copyPositionText(context, detector.routesJson())
                    : null,
              ),
              TfButton.text(
                label: '复制当前坐标',
                icon: Icons.copy,
                onPressed: lookup != null && lookup.found
                    ? () => copyPositionText(context, lookup.toTupleText())
                    : null,
              ),
              TfButton.text(
                label: '复制当前 JSON',
                icon: Icons.data_object,
                onPressed: lookup != null && lookup.found
                    ? () => copyPositionText(context, lookup.toJsonText())
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
