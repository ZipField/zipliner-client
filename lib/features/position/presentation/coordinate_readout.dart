import 'package:flutter/material.dart';
import 'package:zipliner_client/shared/formatting/coordinates.dart';
import 'package:zipliner_client/features/position/application/position_monitor.dart';
import 'package:zipliner_client/app/app_theme.dart';
import 'package:zipliner_client/shared/widgets/section_body.dart';

class CoordinateReadout extends StatelessWidget {
  const CoordinateReadout({super.key, required this.monitor});

  final PositionMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final position = monitor.position;
    final valueStyle = AppFonts.monoStyle(theme.textTheme.headlineSmall);
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget cell(String name, double? value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: labelStyle),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value == null ? '-' : formatUpTo5(value),
              style: valueStyle,
            ),
          ),
        ],
      ),
    );
    return SectionBody(
      child: Row(
        children: [
          cell('X', position?.x),
          cell('Y', position?.y),
          cell('Z', position?.z),
        ],
      ),
    );
  }
}
