import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app.dart';
import '../core/update_checker.dart';
import '../desktop/desktop_overlay.dart';
import '../core/services.dart';
import '../position/position_monitor.dart';
import '../position/position_prefs.dart';
import '../pages/position_page.dart';
import '../pages/weak_network_page.dart';
import '../network/weak_network_controller.dart';

/// 顶层导航。窄屏为底部导航栏，宽屏（桌面）自动切换为侧边导航栏。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _tabs = [
    (
      label: '坐标',
      icon: Icons.my_location_outlined,
      selectedIcon: Icons.my_location,
    ),
    (
      label: '弱网',
      icon: Icons.network_check_outlined,
      selectedIcon: Icons.network_check,
    ),
    (label: '设置', icon: Icons.settings_outlined, selectedIcon: Icons.settings),
  ];

  int _index = 0;
  bool _started = false;
  int _shownDriverHelp = 0;
  WeakNetworkController? _weakNetwork;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final monitor = _monitor = AppServices.of(context).monitor;
    monitor.onDetection = (stop) {
      if (mounted) {
        showTfToast(context, '已识别滑索 ${stop.label}', type: TfToastType.success);
      }
    };
    if (Platform.isAndroid) monitor.addListener(_updateWakelock);
    WidgetsBinding.instance.addPostFrameCallback((_) => monitor.start());
    final services = AppServices.of(context);
    _weakNetwork = services.weakNetwork..addListener(_showDriverHelp);
    _updates = services.updates..addListener(_showPendingUpdate);
    _overlay = services.overlay;
    _overlay?.addListener(_showPendingUpdate);
    _updates!.startAutomaticChecks();
  }

  UpdateChecker? _updates;
  DesktopOverlay? _overlay;

  void _showDriverHelp() {
    final revision = _weakNetwork!.driverHelpRevision;
    if (!mounted || revision <= _shownDriverHelp) return;
    _shownDriverHelp = revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showTfDialog<void>(
        context,
        title: '网络驱动加载失败',
        content: const SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Text(WeakNetworkController.driverHelp),
          ),
        ),
        actions: const [TfDialogAction(label: '知道了')],
      );
    });
  }

  void _showPendingUpdate() {
    final info = _updates?.available;
    if (!mounted ||
        info == null ||
        _updates!.checking ||
        _overlay?.active == true) {
      return;
    }
    presentUpdatePrompt(context, info, automatic: true);
  }

  PositionMonitor? _monitor;
  bool? _wakelock;

  /// Android：连接期间保持屏幕常亮（可在设置中关闭）。
  void _updateWakelock() {
    if (!mounted) return;
    final prefs = TfFramework.of(context).preferences;
    final monitor = _monitor!;
    final want =
        prefs.get(PositionPrefs.keepScreenOn) &&
        (monitor.isConnected || monitor.position != null);
    if (_wakelock == want) return;
    _wakelock = want;
    WakelockPlus.toggle(enable: want).catchError((_) {});
  }

  @override
  void dispose() {
    _weakNetwork?.removeListener(_showDriverHelp);
    _updates?.removeListener(_showPendingUpdate);
    _overlay?.removeListener(_showPendingUpdate);
    _monitor?.removeListener(_updateWakelock);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = _tabs[_index];
    final page = switch (_index) {
      0 => const PositionPage(),
      1 => const WeakNetworkPage(),
      _ => const TfSettingsList(),
    };
    // Material 3 宽屏使用侧边导航栏：顶部栏只应覆盖内容区，否则会压在侧栏上方。
    // 所以此时不把标题交给 TfScaffold，而是在内容区自己放一个标题行。
    final railLayout =
        TfDesign.of(context).id == Material3DesignSystem.systemId &&
        MediaQuery.sizeOf(context).width >=
            const Material3DesignSystem().railBreakpoint;
    return TfScaffold(
      title: railLayout ? null : tab.label,
      selectedIndex: _index,
      onDestinationSelected: (index) => setState(() => _index = index),
      destinations: [
        for (final t in _tabs)
          TfNavDestination(
            icon: t.icon,
            selectedIcon: t.selectedIcon,
            label: t.label,
          ),
      ],
      body: railLayout ? _PaneWithTitle(title: tab.label, child: page) : page,
    );
  }
}

class _PaneWithTitle extends StatelessWidget {
  const _PaneWithTitle({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 64,
          // 与 TfListView 的内容列对齐：最大宽度 720（含左右各 16 的内边距）居中。
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    ),
  );
}
