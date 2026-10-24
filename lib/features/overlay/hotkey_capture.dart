import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zipliner_client/platform/desktop/global_hotkey.dart';

class HotkeyCapture extends StatefulWidget {
  const HotkeyCapture({super.key});

  @override
  State<HotkeyCapture> createState() => _HotkeyCaptureState();
}

class _HotkeyCaptureState extends State<HotkeyCapture> {
  final _focus = FocusNode();

  static final _modifiers = {
    ...LogicalKeyboardKey.expandSynonyms({
      LogicalKeyboardKey.shift,
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.alt,
      LogicalKeyboardKey.meta,
    }),
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.meta,
  };

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  bool _unsupported = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _modifiers.contains(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    if (!GlobalHotkey.supports(event.physicalKey)) {
      setState(() => _unsupported = true);
      return KeyEventResult.handled;
    }
    final label = event.logicalKey.keyLabel.isEmpty
        ? event.physicalKey.debugName ?? '?'
        : event.logicalKey.keyLabel;
    Navigator.of(context)
        .pop((key: event.physicalKey, label: label.toUpperCase()));
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
            ? '不支持该按键，请换一个（字母、数字、F1–F24、方向键等）'
            : '请按下一个键作为切换坐标窗口的快捷键（不支持组合键）',
      ),
    ),
  );
}
