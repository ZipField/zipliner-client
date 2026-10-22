import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tf_framework/tf_framework.dart';

import '../core/services.dart';
import '../network/weak_hotkey.dart';
import '../position/position_prefs.dart';
import 'weak_network_risk_dialog.dart';

class WeakNetworkPage extends StatelessWidget {
  const WeakNetworkPage({super.key});

  Future<void> _setEnabled(BuildContext context, bool value) async {
    final controller = AppServices.of(context).weakNetwork;
    await controller.setEnabled(
      value,
      confirmRisk: () => showWeakNetworkRiskDialog(context),
    );
  }

  Future<void> _editMaximum(BuildContext context) async {
    final controller = AppServices.of(context).weakNetwork;
    final value = await showTfDialog<double>(
      context,
      title: '最大弱网时长',
      content: _MaximumEditor(initial: controller.maximum),
      actions: const [TfDialogAction(label: '取消')],
    );
    if (value != null) await controller.setMaximum(value);
  }

  Future<void> _editHotkey(BuildContext context, bool toggle) async {
    final services = AppServices.of(context);
    final controller = services.weakNetwork;
    controller.hotkeys.suspended = true;
    final overlay = services.overlay;
    if (overlay != null) overlay.hotkeyPaused = true;
    try {
      final binding = await showTfDialog<WeakHotkey>(
        context,
        title: toggle ? '开启／关闭快捷键' : '暂时解除弱网快捷键',
        content: const _ChordCapture(),
        actions: const [TfDialogAction(label: '取消')],
      );
      if (binding == null || !context.mounted) return;
      final prefs = TfFramework.of(context).preferences;
      if (overlay != null && binding.key == PositionPrefs.hotkeyOf(prefs).key) {
        showTfToast(context, '该按键已用于坐标窗口，请换一个按键', type: TfToastType.warning);
        return;
      }
      await controller.setHotkey(toggle: toggle, binding: binding);
    } catch (error) {
      if (context.mounted) {
        showTfToast(context, error.toString(), type: TfToastType.error);
      }
    } finally {
      controller.hotkeys.suspended = false;
      if (overlay != null) overlay.hotkeyPaused = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppServices.of(context).weakNetwork;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => TfListView(
        children: [
          TfSection(
            title: '弱网控制',
            footer: controller.supported
                ? '每次启动后首次启用弱网，需先确认风险提示，再允许管理员权限。未连接游戏时可点击“连接游戏”。'
                : '当前平台仅提供坐标等功能，弱网控制需要在 Windows 电脑上使用。',
            children: [
              TfListTile(
                leading: const Icon(Icons.network_check),
                title: const Text('开启功能'),
                subtitle: Text(controller.status),
                trailing: Switch(
                  value: controller.enabled,
                  onChanged: controller.supported
                      ? (value) => _setEnabled(context, value)
                      : null,
                ),
              ),
              TfListTile(
                title: const Text('暂时解除弱网'),
                subtitle: const Text('暂时恢复游戏连接，随后继续检测。'),
                trailing: TfButton(
                  label: '暂时解除弱网',
                  onPressed: controller.enabled && controller.ready
                      ? controller.releaseBacklog
                      : null,
                ),
              ),
              TfListTile(
                title: const Text('最大弱网时长'),
                subtitle: const Text('10–30 秒。受游戏客户端限制，无法在区域内停留超过约 30 秒。'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${controller.maximum.round()} 秒'),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: controller.supported
                    ? () => _editMaximum(context)
                    : null,
              ),
              TfListTile(
                title: const Text('连接游戏'),
                subtitle: Text(controller.connectionStatus),
                trailing: TfButton(
                  label: controller.reconnecting ? '连接中…' : '连接游戏',
                  onPressed: controller.canConnect
                      ? controller.connectGame
                      : null,
                ),
              ),
              TfListTile(
                title: const Text('在悬浮窗显示弱网状态'),
                trailing: Switch(
                  value: controller.showOverlay,
                  onChanged: controller.supported
                      ? controller.setShowOverlay
                      : null,
                ),
              ),
            ],
          ),
          TfSection(
            title: '设置快捷键',
            children: [
              TfListTile(
                title: const Text('开启／关闭功能'),
                subtitle: Text(controller.toggleHotkey.label),
                trailing: const Icon(Icons.keyboard_outlined),
                onTap: controller.supported
                    ? () => _editHotkey(context, true)
                    : null,
              ),
              TfListTile(
                title: const Text('暂时解除弱网'),
                subtitle: Text(controller.releaseHotkey.label),
                trailing: const Icon(Icons.keyboard_outlined),
                onTap: controller.supported
                    ? () => _editHotkey(context, false)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MaximumEditor extends StatefulWidget {
  const _MaximumEditor({required this.initial});
  final double initial;

  @override
  State<_MaximumEditor> createState() => _MaximumEditorState();
}

class _MaximumEditorState extends State<_MaximumEditor> {
  late double _value = widget.initial;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('${_value.round()} 秒'),
      TfSlider(
        value: _value,
        min: 10,
        max: 30,
        divisions: 20,
        onChanged: (value) => setState(() => _value = value),
      ),
      TfButton(label: '保存', onPressed: () => Navigator.of(context).pop(_value)),
    ],
  );
}

class _ChordCapture extends StatefulWidget {
  const _ChordCapture();
  @override
  State<_ChordCapture> createState() => _ChordCaptureState();
}

class _ChordCaptureState extends State<_ChordCapture> {
  final _focus = FocusNode();
  bool _unsupported = false;
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final binding = WeakHotkey.fromEvent(event);
    if (binding == null) {
      setState(() => _unsupported = true);
    } else {
      Navigator.of(context).pop(binding);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        _unsupported
            ? '继续按下字母、数字、Tab、F1–F24 等按键，可搭配 Ctrl / Alt / Shift。'
            : '请按下要使用的快捷键组合',
      ),
    ),
  );
}
