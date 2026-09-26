import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:window_manager/window_manager.dart';

import '../position/position_monitor.dart';
import '../ui/app_theme.dart';
import 'desktop_overlay.dart';

/// 复用应用设计系统的小型坐标窗；跟随游戏时保留透明、穿透显示。
class OverlayView extends StatefulWidget {
  const OverlayView({super.key, required this.overlay, required this.monitor});

  final DesktopOverlay overlay;
  final PositionMonitor monitor;

  @override
  State<OverlayView> createState() => _OverlayViewState();
}

class _OverlayViewState extends State<OverlayView> {
  static const _toastDuration = Duration(seconds: 2);
  static const _hintDuration = Duration(seconds: 4);
  Timer? _toastTimer;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    widget.monitor.addListener(_onMonitor);
    widget.overlay.addListener(_refresh);
    _hintTimer = Timer(_hintDuration, _refresh);
  }

  @override
  void dispose() {
    widget.monitor.removeListener(_onMonitor);
    widget.overlay.removeListener(_refresh);
    _toastTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _onMonitor() {
    final at = widget.monitor.lastDetectionAt;
    if (at != null && DateTime.now().difference(at) < _toastDuration) {
      _toastTimer?.cancel();
      _toastTimer = Timer(_toastDuration, _refresh);
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final overlay = widget.overlay;
    final follow = overlay.follow;
    final monitor = widget.monitor;
    final at = monitor.lastDetectionAt;
    final toast = at != null && DateTime.now().difference(at) < _toastDuration ? monitor.lastDetection : null;
    final openedAt = overlay.openedAt;
    final showHint = openedAt != null && DateTime.now().difference(openedAt) < _hintDuration;
    // 跟随模式下找不到游戏窗口时，小窗保持可点击，需要露出返回按钮。
    final clickable = !follow || overlay.warning != null;

    final colors = Theme.of(context).colorScheme;
    final valueColor = follow ? Colors.white : colors.onSurface;
    final labelColor = follow ? Colors.white : colors.primary;
    final fontSize = 14.0;
    final shadows = follow
        ? const [Shadow(color: Color(0xFF191919), blurRadius: 5), Shadow(color: Color(0xFF191919), blurRadius: 2)]
        : null;
    final mono = AppFonts.monoStyle(TextStyle(fontSize: fontSize, color: valueColor, shadows: shadows, height: 1.5));
    final label = mono.copyWith(color: labelColor);
    final small = mono.copyWith(fontFamily: AppFonts.family, fontSize: 11, height: 1.3);

    final position = monitor.position;
    final Widget body = position == null
        ? Text(
            monitor.problem?.title ?? (monitor.status.isEmpty ? '正在连接...' : monitor.status),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: mono.copyWith(
              fontFamily: AppFonts.family,
              color: monitor.isError ? (follow ? const Color(0xFFFFB4AB) : colors.error) : valueColor,
            ),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (name, value) in [('X', position.x), ('Y', position.y), ('Z', position.z)])
                Row(
                  children: [
                    SizedBox(width: 20, child: Text(name, style: label)),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          // Avoid displaying negative zero after rounding.
                          _coordinate(value, overlay.decimals),
                          style: mono.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        body,
        if (toast != null)
          Text(
            '已识别滑索 ${toast.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small.copyWith(color: follow ? const Color(0xFF8AB4F8) : colors.primary),
          )
        else if (follow && overlay.warning != null)
          Text('未找到游戏窗口', maxLines: 1, style: small.copyWith(color: const Color(0xFFFFB4AB)))
        else if (showHint)
          Text('按 ${overlay.hotkeyLabel} 返回主界面', maxLines: 1, style: small),
      ],
    );

    final returnButton = Positioned(
      top: 2,
      right: 2,
      // 悬浮视图不在 Navigator 之下，没有 Overlay，不能用 Tooltip。
      child: Semantics(
        button: true,
        label: '返回主界面',
        child: InkResponse(
          onTap: overlay.close,
          radius: 14,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.open_in_full, size: 14, color: labelColor, shadows: shadows),
          ),
        ),
      ),
    );

    Widget fitWindow(Widget child) => FittedBox(
      fit: BoxFit.contain,
      child: SizedBox.fromSize(
        size: follow ? DesktopOverlay.followSize : DesktopOverlay.normalSize,
        child: MediaQuery.withNoTextScaling(child: child),
      ),
    );

    if (follow) {
      return fitWindow(
        ColoredBox(
          color: Colors.transparent,
          child: Stack(
            children: [
              Padding(padding: EdgeInsets.fromLTRB(4, 4, clickable ? 24 : 4, 4), child: content),
              if (clickable) returnButton,
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: fitWindow(
        TfCard(
          padding: EdgeInsets.zero,
          // A desktop window has no app surface behind the glass material.
          child: ColoredBox(
            color: colors.surface,
            child: Stack(
              children: [
                Padding(padding: const EdgeInsets.fromLTRB(12, 12, 28, 12), child: content),
                returnButton,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _coordinate(double value, int decimals) {
  final text = value.toStringAsFixed(decimals);
  return text.startsWith('-') && double.tryParse(text) == 0 ? text.substring(1) : text;
}
