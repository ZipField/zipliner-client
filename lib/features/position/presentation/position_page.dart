import 'package:zipliner_client/app/app_scope.dart';
import 'package:zipliner_client/features/accounts/presentation/account_profile_card.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';

import 'package:zipliner_client/features/position/presentation/position_update_banner.dart';
import 'package:zipliner_client/features/position/presentation/position_welcome_card.dart';
import 'package:zipliner_client/features/position/presentation/position_status_section.dart';
import 'package:zipliner_client/features/overlay/overlay_section.dart';
import 'package:zipliner_client/features/collection/capture_section.dart';

/// 对应原工具的主窗口：连接状态、坐标、坐标窗设置、滑索采集。
class PositionPage extends StatelessWidget {
  const PositionPage({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    unawaited(services.mapNames.load());
    final prefs = TfFramework.of(context).preferences;
    final overlay = services.overlay;
    return ListenableBuilder(
      listenable: Listenable.merge([
        services.monitor,
        ?services.accounts,
        services.mapNames,
        prefs,
        services.updates,
        ?overlay,
      ]),
      builder: (context, _) {
        final update = services.updates.available;
        return TfListView(
          children: [
            const AccountProfileCard(),
            if (update != null) PositionUpdateBanner(update: update),
            if (!services.monitor.hasTokens) const PositionWelcomeCard(),
            PositionStatusSection(monitor: services.monitor),
            if (overlay != null) OverlaySection(overlay: overlay, prefs: prefs),
            CaptureSection(monitor: services.monitor, prefs: prefs),
          ],
        );
      },
    );
  }
}
