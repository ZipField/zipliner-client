import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';

const _acknowledged = TfPreferenceKey<bool>(
  'network.riskAcknowledged',
  defaultValue: false,
);

Future<bool> showWeakNetworkRiskDialog(BuildContext context) async {
  final preferences = TfFramework.of(context).preferences;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (_) => _RiskDialog(wait: !preferences.get(_acknowledged)),
  );
  if (accepted != true) return false;
  // Remember only an affirmative click, never a dismissal or elapsed countdown.
  await preferences.set(_acknowledged, true);
  return true;
}

class _RiskDialog extends StatefulWidget {
  const _RiskDialog({required this.wait});

  final bool wait;

  @override
  State<_RiskDialog> createState() => _RiskDialogState();
}

class _RiskDialogState extends State<_RiskDialog> {
  final _elapsed = Stopwatch();
  Timer? _timer;

  int get _remaining => widget.wait
      ? ((5000 - _elapsed.elapsedMilliseconds) / 1000).ceil().clamp(0, 5)
      : 0;

  @override
  void initState() {
    super.initState();
    if (widget.wait) {
      _elapsed.start();
      _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        if (_remaining == 0) timer.cancel();
        setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _elapsed.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bold = const TextStyle(fontWeight: FontWeight.bold);
    final warning = bold.copyWith(color: theme.colorScheme.error);
    final remaining = _remaining;
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 520),
      title: const Text('弱网功能风险提示'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: '本弱网工具专用于邪道滑索需要弱网的场景，需要'),
                TextSpan(text: '管理员权限', style: bold),
                const TextSpan(text: '，会捕获游戏网络流量，并对游戏网络通信进行延迟处理。'),
                TextSpan(text: '严禁在公开视频网站上炫耀，甚至贴脸官方。', style: warning),
                const TextSpan(text: '\n\n开启弱网后，会根据网络流量和当前坐标'),
                TextSpan(text: '自动识别', style: bold),
                const TextSpan(text: '。由于该工具并不能精确判断何时进入区域，为避免游戏过程中频繁出现弱网和断连，请'),
                TextSpan(text: '确保在常规游戏期间关闭该功能', style: bold),
                const TextSpan(text: '，并在错误判断时及时解除弱网。\n\n弱网操作'),
                TextSpan(text: '存在风险', style: warning),
                const TextSpan(
                  text: '，可能造成延迟、断线重连或游戏状态异常。目前使用NetLimiter在内的弱网工具从未收到处罚，但',
                ),
                TextSpan(text: '不代表官方许可，也不能保证今后绝对安全。', style: bold),
                const TextSpan(text: '\n\n'),
                TextSpan(text: '请在知悉风险后决定是否继续。', style: bold),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: remaining > 0
              ? null
              : () {
                  if (_remaining == 0) Navigator.of(context).pop(true);
                },
          child: Text(remaining > 0 ? '我已知悉，继续使用（$remaining 秒）' : '我已知悉，继续使用'),
        ),
      ],
    );
  }
}
