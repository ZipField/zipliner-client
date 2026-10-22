import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:window_manager/window_manager.dart';

import '../position/position_monitor.dart';
import '../position/position_prefs.dart';
import '../position/token_store.dart';
import '../position/zipline_realtime_detector.dart';
import '../skland/skland_client.dart';
import '../skland/skland_models.dart';
import '../ui/app_theme.dart';
import 'desktop_overlay.dart';
import 'game_window_locator.dart';
import 'overlay_view.dart';

/// Display-only entry point. No account storage, API subscription, networking
/// helper, global shortcuts, app log, or single-instance mutex is initialized.
Future<void> runCoordinateWindow(List<String> arguments) async {
  if (arguments.length != 4) exit(2);
  final port = int.tryParse(arguments[1]);
  final parentPid = int.tryParse(arguments[3]);
  if (port == null || port < 1 || port > 65535 || parentPid == null) exit(2);
  await windowManager.ensureInitialized();
  await windowManager.hide();
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
    timeout: const Duration(seconds: 5),
  );
  final input = StreamIterator(
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  void send(Map<String, dynamic> message) =>
      socket.write('${jsonEncode(message)}\n');
  send({'hello': arguments[2]});
  if (!await input.moveNext().timeout(const Duration(seconds: 10))) exit(0);
  final first = jsonDecode(input.current) as Map<String, dynamic>;
  if (first['command'] != 'snapshot') exit(0);
  final initialPreferences = (first['preferences'] as Map)
      .cast<String, Object>();
  final framework = await TfFramework.initialize(
    designSystems: const [
      Material3DesignSystem(),
      LiquidGlassDesignSystem(warmUpShaders: false),
    ],
    store: TfMemoryPreferenceStore(initialPreferences),
  );
  final monitor = _DisplayMonitor()..update(first);
  final overlay = DesktopOverlay.window(
    framework.preferences,
    locator: GameWindowLocator(
      companionPid: parentPid,
      targetExecutable: () =>
          framework.preferences.get(PositionPrefs.gameExecutable),
    ),
    onReturn: () => send({'event': 'return_main'}),
  );
  await overlay.updatePresentation(first);
  String? lastWarning;
  overlay.addListener(() {
    if (lastWarning == overlay.warning) return;
    lastWarning = overlay.warning;
    send({'event': 'warning', 'message': lastWarning});
  });
  await windowManager.setTitle('Zipliner Client · 悬浮窗');
  await overlay.initialize();
  await overlay.open();
  runApp(
    TfApp(
      framework: framework,
      title: 'Zipliner Client · 悬浮窗',
      locale: const Locale('zh'),
      home: Material(
        type: MaterialType.transparency,
        child: OverlayView(overlay: overlay, monitor: monitor),
      ),
      builder: (context, child) =>
          Theme(data: refineTheme(Theme.of(context)), child: child!),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => send({'event': 'ready'}));
  try {
    while (await input.moveNext()) {
      final message = jsonDecode(input.current) as Map<String, dynamic>;
      if (message['command'] == 'close') break;
      if (message['command'] != 'snapshot') continue;
      if (message['preferences'] case final Map values) {
        await framework.preferences.import(values.cast<String, Object?>());
      }
      await overlay.updatePresentation(
        message,
        restyle: message.containsKey('preferences'),
      );
      monitor.update(message);
    }
  } finally {
    overlay.dispose();
    monitor.dispose();
    socket.destroy();
  }
  // EOF also closes the display if the parent crashes or exits.
  exit(0);
}

class _DisplayMonitor extends PositionMonitor {
  _DisplayMonitor()
    : super(
        client: SklandClient(),
        tokens: TokenRepository(MemoryTokenStore()),
        captureDirectory: () async => Directory.systemTemp.path,
      );

  void update(Map<String, dynamic> message) {
    final p = message['position'] as List?;
    position = p == null
        ? null
        : PositionSnapshot(
            (p[0] as num).toDouble(),
            (p[1] as num).toDouble(),
            (p[2] as num).toDouble(),
          );
    status = message['status'] as String? ?? '未连接';
    isError = message['isError'] == true;
    final at = message['detectionAt'] as int?;
    lastDetectionAt = at == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(at);
    final stop = message['detection'] as Map?;
    lastDetection = stop == null
        ? null
        : DetectedZiplineStop(
            order: stop['order'] as int,
            x: stop['x'] as int,
            y: (stop['y'] as num).toDouble(),
            z: stop['z'] as int,
            direction: stop['direction'] as String,
            distance: (stop['distance'] as num).toDouble(),
            heightOffset: (stop['heightOffset'] as num).toDouble(),
          );
    notifyListeners();
  }
}
