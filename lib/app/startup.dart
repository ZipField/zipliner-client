import 'dart:async';

import 'package:flutter/material.dart';

/// Render the first frame before loading preferences and creating services.
class ClientStartup extends StatefulWidget {
  const ClientStartup({super.key, required this.load});
  final Future<Widget> Function() load;

  @override
  State<ClientStartup> createState() => _ClientStartupState();
}

class _ClientStartupState extends State<ClientStartup> {
  Widget? _application;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final application = await widget.load();
      if (mounted) setState(() => _application = application);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          context: ErrorDescription('初始化 Zipliner Client'),
        ),
      );
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) =>
      _application ??
      MaterialApp(
        title: 'Zipliner Client',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xff555b99),
        ),
        home: Scaffold(
          body: Center(
            child: AlertDialog(
              title: Text(_failed ? '启动未完成' : '正在启动…'),
              content: SizedBox(
                width: 360,
                child: _failed
                    ? const Text('初始化失败，请重试。若仍无法启动，请提供客户端日志。')
                    : const Row(
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                          SizedBox(width: 20),
                          Expanded(child: Text('正在加载配置，请稍候。')),
                        ],
                      ),
              ),
              actions: _failed
                  ? [TextButton(onPressed: _load, child: const Text('重试'))]
                  : null,
            ),
          ),
        ),
      );
}
