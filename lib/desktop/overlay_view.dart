import 'dart:async';
import 'dart:math' as math;

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
    final labelColor = follow ? Colors.white : colors.onSurfaceVariant;
    final fontSize = follow ? 14.0 : 18.0;
    final shadows = follow
        ? const [Shadow(color: Color(0xFF191919), blurRadius: 5), Shadow(color: Color(0xFF191919), blurRadius: 2)]
        : null;
    final mono = AppFonts.monoStyle(TextStyle(fontSize: fontSize, color: valueColor, shadows: shadows, height: 1));
    final label = mono.copyWith(color: labelColor, fontSize: 10, fontWeight: FontWeight.w500);
    final small = mono.copyWith(
      fontFamily: AppFonts.family,
      fontSize: follow ? 10 : 9,
      height: 1.2,
      color: follow ? Colors.white : colors.onSurfaceVariant,
    );

    final position = monitor.position;
    final target = overlay.target;
    final distance = target == null || position == null
        ? null
        : math.sqrt(
            (position.x - target.x) * (position.x - target.x) +
                (position.y - target.y) * (position.y - target.y) +
                (position.z - target.z) * (position.z - target.z),
          );

    Widget readout(double value) {
      final text = _coordinate(value, overlay.decimals);
      final dot = text.indexOf('.');
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: dot < 0 ? text : text.substring(0, dot)),
            if (dot >= 0)
              TextSpan(
                text: text.substring(dot),
                style: TextStyle(
                  color: follow ? Colors.white : colors.onSurfaceVariant,
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
        style: mono.copyWith(fontWeight: FontWeight.w600),
      );
    }

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
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        height: 10,
                        margin: const EdgeInsets.only(right: 7),
                        decoration: BoxDecoration(
                          color: follow ? Colors.white70 : colors.primary.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      SizedBox(
                        width: 12,
                        height: 18,
                        child: Align(
                          alignment: Alignment.center,
                          child: Text(name, style: label),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: readout(value),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!follow) ...[
          SizedBox(
            height: 16,
            child: Row(
              children: [
                Icon(Icons.my_location_rounded, size: 10, color: colors.primary),
                const SizedBox(width: 5),
                Text('坐标', style: small.copyWith(fontWeight: FontWeight.w500, letterSpacing: 1)),
              ],
            ),
          ),
          const SizedBox(height: 3),
        ],
        body,
        if (target != null) ...[
          const SizedBox(height: 5),
          Row(
            children: [
              Text('目标', style: small.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '(${_coordinate(target.x, overlay.decimals)}, ${_coordinate(target.y, overlay.decimals)}, ${_coordinate(target.z, overlay.decimals)})',
                    style: mono.copyWith(fontSize: follow ? 9.5 : 9, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                distance == null ? '-- m' : '${distance.toStringAsFixed(2)} m',
                style: small.copyWith(
                  fontWeight: FontWeight.w700,
                  color: follow ? Colors.white : colors.primary,
                ),
              ),
            ],
          ),
        ],
        if (toast != null || (follow && overlay.warning != null) || showHint) const SizedBox(height: 4),
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
      top: 6,
      right: 8,
      // 悬浮视图不在 Navigator 之下，没有 Overlay，不能用 Tooltip。
      child: Semantics(
        button: true,
        label: '返回主界面',
        child: InkResponse(
          onTap: overlay.close,
          radius: 14,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              Icons.open_in_full,
              size: 12,
              color: follow ? Colors.white : colors.onSurfaceVariant,
              shadows: shadows,
            ),
          ),
        ),
      ),
    );

    Widget fitWindow(Widget child) => FittedBox(
      fit: BoxFit.contain,
      child: SizedBox.fromSize(
        size: overlay.baseSize,
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
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(colors.primary.withValues(alpha: 0.035), colors.surfaceContainerLow),
                  colors.surface,
                ],
              ),
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
                  child: Center(child: content),
                ),
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
