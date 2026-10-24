import 'package:flutter/material.dart';

import 'package:zipliner_client/platform/desktop/game_window_locator.dart';

Future<String?> chooseGameWindow(BuildContext context, String selected) =>
    showDialog<String>(
      context: context,
      builder: (_) => _GameWindowPicker(selected: selected),
    );

class _GameWindowPicker extends StatefulWidget {
  const _GameWindowPicker({required this.selected});
  final String selected;
  @override
  State<_GameWindowPicker> createState() => _GameWindowPickerState();
}

class _GameWindowPickerState extends State<_GameWindowPicker> {
  final _locator = GameWindowLocator();
  late List<GameWindowChoice> _windows = _locator.visibleWindows();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('选择游戏窗口')),
        IconButton(
          tooltip: '刷新窗口列表',
          onPressed: () => setState(() => _windows = _locator.visibleWindows()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    content: SizedBox(
      width: 560,
      height: 400,
      child: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('所选程序同时用于悬浮窗跟随、窗口检测和弱网。切换时会关闭当前弱网，之后可重新开启。'),
          ),
          ListTile(
            title: const Text('Endfield.exe（默认）'),
            trailing: widget.selected.toLowerCase() == 'endfield.exe'
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(context, 'Endfield.exe'),
          ),
          const Divider(),
          if (_windows.isEmpty) const Text('暂无可选择的窗口，请先打开目标程序后刷新。'),
          for (final window in _windows)
            ListTile(
              title: Text(window.title),
              subtitle: Text(window.executable),
              trailing:
                  widget.selected.toLowerCase() ==
                      window.executable.toLowerCase()
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(context, window.executable),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}
