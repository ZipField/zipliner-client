import 'package:zipliner_client/app/app_scope.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/overlay/desktop_overlay.dart';
import 'package:zipliner_client/platform/desktop/game_window_picker.dart';
import 'package:zipliner_client/features/overlay/follow_placement.dart';
import 'package:zipliner_client/app/app_preferences.dart';
import 'package:zipliner_client/app/app_theme.dart';
import 'package:zipliner_client/shared/widgets/section_body.dart';
import 'package:zipliner_client/shared/formatting/coordinates.dart';

import 'target_coordinate_editor.dart';
import 'hotkey_capture.dart';

class OverlaySection extends StatelessWidget {
  const OverlaySection({super.key, required this.overlay, required this.prefs});

  final DesktopOverlay overlay;
  final TfPreferencesController prefs;

  Future<void> _captureHotkey(BuildContext context) async {
    overlay.hotkeyPaused = true;
    final ({PhysicalKeyboardKey key, String label})? result;
    try {
      result = await showTfDialog<({PhysicalKeyboardKey key, String label})>(
        context,
        title: '设置快捷键',
        content: const HotkeyCapture(),
        actions: const [TfDialogAction(label: '取消')],
      );
    } finally {
      overlay.hotkeyPaused = false;
    }
    if (result == null) return;
    await AppPreferences.setHotkey(prefs, result.key, result.label);
    overlay.registerHotkey();
  }

  /// 坐标窗独立显示，主界面始终保留。
  Future<void> _open(BuildContext context) async {
    if (!prefs.get(AppPreferences.overlayHintShown)) {
      final hotkey = AppPreferences.hotkeyOf(prefs).label;
      final follow = overlay.follow;
      await showTfAlert(
        context,
        title: '坐标窗口怎么用',
        message:
            '打开独立的坐标小窗，主界面仍然保留，可从任务栏打开。\n\n'
            '按 $hotkey 显示或隐藏坐标窗。'
            '${follow ? '\n\n已开启“跟随游戏窗口”：坐标窗会贴在游戏窗口上，鼠标可以穿透。' : '\n\n可以拖动小窗调整位置。'}',
        buttonLabel: '知道了',
      );
      await prefs.set(AppPreferences.overlayHintShown, true);
    }
    await overlay.open();
  }

  Future<void> _choosePosition(BuildContext context) async {
    final current = AppPreferences.position(prefs);
    final chosen = await showTfActionSheet<FollowPosition>(
      context,
      title: '显示位置',
      actions: [
        for (final p in FollowPosition.values)
          TfSheetAction(
            label: p.label,
            value: p,
            icon: p == current ? Icons.check : null,
          ),
      ],
    );
    if (chosen == null) return;
    await prefs.set(AppPreferences.followPosition, chosen.name);
    await overlay.refresh();
  }

  Future<void> _editTarget(BuildContext context) async {
    final result =
        await showTfDialog<({bool clear, double x, double y, double z})>(
          context,
          title: '目标坐标',
          content: TargetCoordinateEditor(
            initial: AppPreferences.target(prefs),
          ),
          actions: const [TfDialogAction(label: '取消')],
        );
    if (result == null) return;
    if (result.clear) {
      await AppPreferences.clearTarget(prefs);
    } else {
      await AppPreferences.setTarget(prefs, (
        x: result.x,
        y: result.y,
        z: result.z,
      ));
    }
    await overlay.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final hotkey = AppPreferences.hotkeyOf(prefs);
    final follow = prefs.get(AppPreferences.followGame);
    final position = AppPreferences.position(prefs);
    final offset = AppPreferences.offset(prefs, position);
    final target = AppPreferences.target(prefs);
    final warnings = [?overlay.hotkeyWarning, ?overlay.warning];

    Widget slider(
      String label,
      double value,
      bool negative,
      void Function(double) onChanged,
    ) => SectionBody(
      vertical: 4,
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(label)),
          Expanded(
            child: TfSlider(
              value: value.clamp(negative ? -500 : 0, 500).toDouble(),
              min: negative ? -500 : 0,
              max: 500,
              divisions: negative ? 100 : 50,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              value.round().toString(),
              textAlign: TextAlign.right,
              style: AppFonts.monoStyle(null),
            ),
          ),
        ],
      ),
    );

    return TfSection(
      title: '坐标显示',
      footer: '坐标窗独立显示，主界面始终保留；按 ${hotkey.label} 显示或隐藏坐标窗。',
      children: [
        TfListTile(
          leading: const Icon(Icons.picture_in_picture_alt_outlined),
          title: const Text('在悬浮窗显示坐标'),
          trailing: TfSwitch(
            value: overlay.active,
            onChanged: (value) async {
              if (value) {
                await _open(context);
              } else {
                await overlay.close();
              }
            },
          ),
        ),
        TfListTile(
          leading: const Icon(Icons.flag_outlined),
          title: const Text('目标坐标'),
          subtitle: Text(
            target == null
                ? '未设置；设置后浮窗底部会显示目标和三维直线距离'
                : 'X ${formatUpTo5(target.x)} · Y ${formatUpTo5(target.y)} · Z ${formatUpTo5(target.z)}\n浮窗底部实时显示三维直线距离',
          ),
          trailing: TfButton.secondary(
            label: target == null ? '设置' : '修改',
            onPressed: () => _editTarget(context),
          ),
        ),
        TfListTile(
          leading: const Icon(Icons.keyboard_outlined),
          title: const Text('快捷键'),
          subtitle: Text(hotkey.label, style: AppFonts.monoStyle(null)),
          trailing: TfButton.secondary(
            label: '设置快捷键',
            onPressed: () => _captureHotkey(context),
          ),
        ),
        if (overlay.followSupported) ...[
          TfListTile(
            leading: const Icon(Icons.window_outlined),
            title: const Text('游戏窗口'),
            subtitle: Text(
              prefs
                  .get(AppPreferences.gameExecutable)
                  .split(RegExp(r'[\\/]'))
                  .last,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final target = await chooseGameWindow(
                context,
                prefs.get(AppPreferences.gameExecutable),
              );
              if (target == null || !context.mounted) return;
              try {
                await AppScope.of(context).weakNetwork
                    .setTargetExecutable(target);
                await overlay.refresh();
              } catch (error) {
                if (context.mounted) {
                  showTfToast(
                    context,
                    '切换窗口失败：$error',
                    type: TfToastType.error,
                  );
                }
              }
            },
          ),
          TfListTile(
            leading: const Icon(Icons.filter_center_focus),
            title: const Text('跟随游戏窗口'),
            subtitle: const Text('让悬浮窗跟随所选游戏窗口'),
            trailing: TfSwitch(
              value: follow,
              onChanged: (value) async {
                await prefs.set(AppPreferences.followGame, value);
                await overlay.refresh();
              },
            ),
          ),
          if (follow) ...[
            TfListTile(
              leading: const Icon(Icons.open_with),
              title: const Text('显示位置'),
              subtitle: Text(position.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _choosePosition(context),
            ),
            slider(
              '左右偏移',
              offset.h,
              position.allowsNegativeHorizontal,
              (v) => AppPreferences.setOffset(
                prefs,
                position,
                h: v.roundToDouble(),
              ),
            ),
            slider(
              '上下偏移',
              offset.v,
              position.allowsNegativeVertical,
              (v) => AppPreferences.setOffset(
                prefs,
                position,
                v: v.roundToDouble(),
              ),
            ),
          ],
        ],
        for (final w in warnings)
          SectionBody(
            child: TfBanner(type: TfToastType.warning, message: w),
          ),
      ],
    );
  }
}
