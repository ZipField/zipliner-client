import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/services.dart';
import '../core/update_checker.dart';
import '../desktop/desktop_overlay.dart';
import '../desktop/global_hotkey.dart';
import '../position/follow_placement.dart';
import '../position/formatting.dart';
import '../position/friendly_error.dart';
import '../position/position_monitor.dart';
import '../position/position_prefs.dart';
import '../ui/app_theme.dart';
import '../ui/section_body.dart';
import 'account_manager_page.dart';
import 'help_page.dart';
import 'login_page.dart';

/// 对应原工具的主窗口：连接状态、坐标、坐标窗设置、滑索采集。
class PositionPage extends StatelessWidget {
  const PositionPage({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final prefs = TfFramework.of(context).preferences;
    final overlay = services.overlay;
    return ListenableBuilder(
      listenable: Listenable.merge([services.monitor, prefs, services.updates, ?overlay]),
      builder: (context, _) {
        final update = services.updates.available;
        return TfListView(
          children: [
            if (update != null) _UpdateBanner(update: update),
            if (!services.monitor.hasTokens) const _WelcomeCard(),
            _StatusSection(monitor: services.monitor),
            TfSection(
              title: '坐标同步',
              children: [
                const TfToggleSetting(
                  key: PositionPrefs.requestPolling,
                  title: '主动刷新坐标',
                  subtitle: '关闭时仅接收服务器自动推送。',
                ).build(context, prefs),
                TfSliderSetting(
                  key: PositionPrefs.requestIntervalSeconds,
                  title: '请求速度',
                  subtitle: '开启主动刷新后生效。间隔越小，请求越快；实际更新速度取决于服务器。',
                  min: 0.2,
                  max: 10,
                  divisions: 98,
                  format: (value) => '${value.toStringAsFixed(1)} 秒',
                ).build(context, prefs),
              ],
            ),
            if (overlay != null) _OverlaySection(overlay: overlay, prefs: prefs),
            _CaptureSection(monitor: services.monitor, prefs: prefs),
          ],
        );
      },
    );
  }
}

Future<void> _copy(BuildContext context, String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) showTfToast(context, '已复制到剪贴板', type: TfToastType.success);
  } catch (_) {
    if (context.mounted) showTfToast(context, '复制失败，剪贴板可能正被其他程序占用，请稍后重试', type: TfToastType.error);
  }
}

void _openAccounts(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountManagerPage()));

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.update});

  final UpdateInfo update;

  @override
  Widget build(BuildContext context) => TfCard(
    child: Row(
      children: [
        const Icon(Icons.new_releases_outlined),
        const SizedBox(width: 12),
        Expanded(child: Text('发现新版本 ${update.version}，下载后解压覆盖旧文件即可，账号和设置都会保留。')),
        const SizedBox(width: 12),
        TfButton(label: '去下载', onPressed: () => launchUrl(Uri.parse(update.url))),
      ],
    ),
  );
}

/// 第一次打开、还没有账号时的上手引导。
class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget step(int n, String title, String detail) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text('$n', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              Text(detail, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
    return TfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text('欢迎使用终末地坐标工具', style: theme.textTheme.titleMedium),
          step(1, '登录森空岛账号', '推荐用森空岛 App 扫码，国际服选 SKPort。'),
          step(2, '打开位置同步', '工具会检测并提示你一键开启，也可以在森空岛地图工具右下角打开。'),
          step(3, '进入游戏', '登录对应角色后坐标会自动显示，断线会自动重连。'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TfButton(label: '登录森空岛账号', icon: Icons.login, onPressed: () => addAccount(context)),
              TfButton.text(
                label: '使用帮助',
                icon: Icons.help_outline,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HelpPage())),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusSection extends StatelessWidget {
  const _StatusSection({required this.monitor});

  final PositionMonitor monitor;

  Future<void> _chooseRole(BuildContext context) async {
    final key = await showTfActionSheet<String>(
      context,
      title: '切换角色',
      actions: [
        for (final role in monitor.roles)
          TfSheetAction(
            label: '${role.displayName}（服务器 ${role.binding.serverId}）',
            value: role.key,
            icon: role.key == monitor.activeRole?.key ? Icons.check : Icons.person_outline,
          ),
      ],
    );
    if (key != null) unawaited(monitor.switchRole(key));
  }

  Future<void> _agreePolicy(BuildContext context) async {
    final ok = await showTfConfirm(
      context,
      title: '同意位置同步政策',
      message:
          '森空岛地图的“位置同步”需要角色同意相关政策后才会下发坐标。确认后将以当前角色调用森空岛的同意接口，'
          '效果等同于在森空岛地图工具中打开“位置同步”。',
      confirmLabel: '同意并连接',
    );
    if (ok) unawaited(monitor.agreePolicyAndConnect());
  }

  Future<void> _fix(BuildContext context, FixAction action) async {
    switch (action) {
      case FixAction.login:
        await addAccount(context);
      case FixAction.relogin:
        final failed = monitor.failedAccounts.keys.toSet();
        final accounts = await AppServices.of(context).tokens.list();
        final target = accounts.where((a) => failed.contains(a.id)).toList();
        if (!context.mounted) return;
        // 只有一个失效账号时直接打开重新登录，多个时让用户在账号管理里选择。
        target.length == 1 ? await reloginAccount(context, target.single) : _openAccounts(context);
      case FixAction.agreePolicy:
        await _agreePolicy(context);
      case FixAction.reconnect:
        await monitor.start();
    }
  }

  static String _fixLabel(FixAction action) => switch (action) {
    FixAction.login => '登录',
    FixAction.relogin => '重新登录',
    FixAction.agreePolicy => '同意并连接',
    FixAction.reconnect => '重新连接',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final role = monitor.activeRole;
    final position = monitor.position;
    final problem = monitor.problem;
    final retryIn = monitor.retryInSeconds;
    final (icon, color) = monitor.isError
        ? (Icons.error_outline, scheme.error)
        : monitor.isConnected || position != null
        ? (Icons.check_circle, Colors.green)
        : (Icons.radio_button_unchecked, scheme.onSurfaceVariant);

    final title = problem?.title ?? (monitor.status.isEmpty ? '正在连接...' : monitor.status);
    final subtitle = [if (retryIn != null) '$retryIn 秒后自动重连', ?monitor.warning].join('\n');

    return TfSection(
      title: '状态',
      children: [
        TfListTile(
          leading: monitor.isConnecting ? const TfProgress.circular() : Icon(icon, color: color),
          title: Text(title),
          subtitle: subtitle.isEmpty
              ? null
              : Text(subtitle, style: TextStyle(color: monitor.warning != null ? scheme.error : null)),
        ),
        if (problem?.hint != null)
          SectionBody(
            child: TfBanner(type: problem!.retryable ? TfToastType.info : TfToastType.warning, message: problem.hint!),
          ),
        _CoordinateReadout(monitor: monitor),
        TfListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('角色'),
          subtitle: Text(role == null ? '未选择' : '${role.displayName} · 服务器 ${role.binding.serverId}'),
          trailing: monitor.roles.length > 1 ? const Icon(Icons.chevron_right) : null,
          onTap: monitor.roles.length > 1 && !monitor.isConnecting ? () => _chooseRole(context) : null,
        ),
        TfListTile(
          leading: const Icon(Icons.map_outlined),
          title: const Text('地图'),
          subtitle: Text(
            monitor.mapId == null ? '等待坐标同步' : [monitor.mapId, ?monitor.levelId].join(' / '),
            style: AppFonts.monoStyle(theme.textTheme.bodyMedium),
          ),
        ),
        SectionBody(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!monitor.hasTokens)
                TfButton(label: '登录', icon: Icons.login, onPressed: () => addAccount(context))
              else if (problem?.action != null && problem!.action != FixAction.reconnect)
                TfButton(label: _fixLabel(problem.action!), onPressed: () => _fix(context, problem.action!)),
              TfButton.secondary(
                label: retryIn != null ? '立即重连' : '重新连接',
                icon: Icons.refresh,
                onPressed: monitor.isConnecting ? null : monitor.start,
              ),
              TfButton.secondary(
                label: '账号管理',
                icon: Icons.manage_accounts_outlined,
                onPressed: monitor.isConnecting ? null : () => _openAccounts(context),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CoordinateReadout extends StatelessWidget {
  const _CoordinateReadout({required this.monitor});

  final PositionMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final position = monitor.position;
    final valueStyle = AppFonts.monoStyle(theme.textTheme.headlineSmall);
    final labelStyle = theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget cell(String name, double? value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: labelStyle),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value == null ? '-' : formatUpTo5(value), style: valueStyle),
          ),
        ],
      ),
    );
    return SectionBody(child: Row(children: [cell('X', position?.x), cell('Y', position?.y), cell('Z', position?.z)]));
  }
}

/// 主页读数不需要原工具的对齐空格，只保留最多 5 位小数。
String formatUpTo5(double value) => formatCoordinate(value).trim().replaceFirst(RegExp(r'\.$'), '');

class _OverlaySection extends StatelessWidget {
  const _OverlaySection({required this.overlay, required this.prefs});

  final DesktopOverlay overlay;
  final TfPreferencesController prefs;

  Future<void> _captureHotkey(BuildContext context) async {
    overlay.hotkeyPaused = true;
    final ({PhysicalKeyboardKey key, String label})? result;
    try {
      result = await showTfDialog<({PhysicalKeyboardKey key, String label})>(
        context,
        title: '设置快捷键',
        content: const _HotkeyCapture(),
        actions: const [TfDialogAction(label: '取消')],
      );
    } finally {
      overlay.hotkeyPaused = false;
    }
    if (result == null) return;
    await PositionPrefs.setHotkey(prefs, result.key, result.label);
    overlay.registerHotkey();
  }

  /// 第一次打开时先说明怎么回到主界面，避免用户以为程序“变小了回不去”。
  Future<void> _open(BuildContext context) async {
    if (!prefs.get(PositionPrefs.overlayHintShown)) {
      final hotkey = PositionPrefs.hotkeyOf(prefs).label;
      final follow = overlay.follow;
      await showTfAlert(
        context,
        title: '坐标窗口怎么用',
        message:
            '打开后主界面会隐藏，变成一个置顶的小坐标窗，可以拖动。\n\n'
            '回到主界面：按 $hotkey，或点小窗右上角的按钮。'
            '${follow ? '\n\n已开启“跟随游戏窗口”：小窗会贴在游戏窗口上并且鼠标可以穿透，这时只能按 $hotkey 返回。' : ''}',
        buttonLabel: '知道了',
      );
      await prefs.set(PositionPrefs.overlayHintShown, true);
    }
    await overlay.open();
  }

  Future<void> _choosePosition(BuildContext context) async {
    final current = PositionPrefs.position(prefs);
    final chosen = await showTfActionSheet<FollowPosition>(
      context,
      title: '显示位置',
      actions: [
        for (final p in FollowPosition.values)
          TfSheetAction(label: p.label, value: p, icon: p == current ? Icons.check : null),
      ],
    );
    if (chosen == null) return;
    await prefs.set(PositionPrefs.followPosition, chosen.name);
    await overlay.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final hotkey = PositionPrefs.hotkeyOf(prefs);
    final follow = prefs.get(PositionPrefs.followGame);
    final position = PositionPrefs.position(prefs);
    final offset = PositionPrefs.offset(prefs, position);
    final warnings = [?overlay.hotkeyWarning, ?overlay.warning];

    Widget slider(String label, double value, bool negative, void Function(double) onChanged) => SectionBody(
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
            child: Text(value.round().toString(), textAlign: TextAlign.right, style: AppFonts.monoStyle(null)),
          ),
        ],
      ),
    );

    return TfSection(
      title: '坐标显示',
      footer: '打开后主窗口会变成置顶的小坐标窗，按 ${hotkey.label} 或点右上角按钮返回。',
      children: [
        TfListTile(
          leading: const Icon(Icons.picture_in_picture_alt_outlined),
          title: const Text('显示坐标窗口'),
          trailing: TfButton(label: '打开', onPressed: () => _open(context)),
        ),
        TfListTile(
          leading: const Icon(Icons.keyboard_outlined),
          title: const Text('快捷键'),
          subtitle: Text(hotkey.label, style: AppFonts.monoStyle(null)),
          trailing: TfButton.secondary(label: '设置快捷键', onPressed: () => _captureHotkey(context)),
        ),
        if (overlay.followSupported) ...[
          TfListTile(
            leading: const Icon(Icons.filter_center_focus),
            title: const Text('跟随游戏窗口'),
            subtitle: const Text('只读取 endfield.exe 的窗口位置，不读取游戏内存、不注入、不发送输入'),
            trailing: TfSwitch(
              value: follow,
              onChanged: (value) async {
                await prefs.set(PositionPrefs.followGame, value);
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
              (v) => PositionPrefs.setOffset(prefs, position, h: v.roundToDouble()),
            ),
            slider(
              '上下偏移',
              offset.v,
              position.allowsNegativeVertical,
              (v) => PositionPrefs.setOffset(prefs, position, v: v.roundToDouble()),
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

class _HotkeyCapture extends StatefulWidget {
  const _HotkeyCapture();

  @override
  State<_HotkeyCapture> createState() => _HotkeyCaptureState();
}

class _HotkeyCaptureState extends State<_HotkeyCapture> {
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
    if (event is! KeyDownEvent || _modifiers.contains(event.logicalKey)) return KeyEventResult.handled;
    if (!GlobalHotkey.supports(event.physicalKey)) {
      setState(() => _unsupported = true);
      return KeyEventResult.handled;
    }
    final label = event.logicalKey.keyLabel.isEmpty ? event.physicalKey.debugName ?? '?' : event.logicalKey.keyLabel;
    Navigator.of(context).pop((key: event.physicalKey, label: label.toUpperCase()));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(_unsupported ? '不支持该按键，请换一个（字母、数字、F1–F24、方向键等）' : '请按下一个键作为切换坐标窗口的快捷键（不支持组合键）'),
    ),
  );
}

class _CaptureSection extends StatelessWidget {
  const _CaptureSection({required this.monitor, required this.prefs});

  final PositionMonitor monitor;
  final TfPreferencesController prefs;

  Future<void> _start(BuildContext context) async {
    if (monitor.hasDetections) {
      final ok = await showTfConfirm(context, title: '确认开始采集', message: '开始新的采集会清除当前已识别的滑索数据，是否继续？', destructive: true);
      if (!ok) return;
    }
    await monitor.startCapture();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lookup = monitor.lookupResult;
    final detector = monitor.detector;
    final realtime = monitor.realtimeText;
    final mono = AppFonts.monoStyle(theme.textTheme.bodyMedium);
    return TfSection(
      title: '数据采集',
      children: [
        TfListTile(
          leading: const Icon(Icons.save_alt_outlined),
          title: const Text('记录采集数据到文件'),
          trailing: TfSwitch(
            value: monitor.recordCapture,
            onChanged: monitor.isCapturing
                ? null
                : (value) {
                    monitor.recordCapture = value;
                    prefs.set(PositionPrefs.recordCapture, value);
                  },
          ),
        ),
        SectionBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(monitor.captureStatusText, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TfButton(
                    label: '开始采集',
                    icon: Icons.play_arrow,
                    onPressed: monitor.isCapturing ? null : () => _start(context),
                  ),
                  TfButton.secondary(
                    label: '停止采集',
                    icon: Icons.stop,
                    onPressed: monitor.isCapturing ? monitor.stopCapture : null,
                  ),
                  TfButton.secondary(
                    label: '手动获取当前滑索',
                    icon: Icons.ads_click,
                    loading: monitor.isLoadingMarks,
                    onPressed: monitor.position != null && !monitor.isLoadingMarks ? monitor.manualDetect : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (monitor.manualResultText != null)
          TfListTile(
            leading: const Icon(Icons.place_outlined),
            title: const Text('当前滑索'),
            subtitle: SelectableText(monitor.manualResultText!, style: mono),
          ),
        if (realtime != null) SectionBody(child: SelectableText(realtime, style: mono)),
        SectionBody(
          vertical: 8,
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              TfButton.text(
                label: '复制滑索 JSON',
                icon: Icons.copy,
                onPressed: detector != null && monitor.hasDetections
                    ? () => _copy(context, detector.marksJson())
                    : null,
              ),
              TfButton.text(
                label: '复制路线集合',
                icon: Icons.route_outlined,
                onPressed: detector != null && monitor.hasDetections
                    ? () => _copy(context, detector.routesJson())
                    : null,
              ),
              TfButton.text(
                label: '复制当前坐标',
                icon: Icons.copy,
                onPressed: lookup != null && lookup.found ? () => _copy(context, lookup.toTupleText()) : null,
              ),
              TfButton.text(
                label: '复制当前 JSON',
                icon: Icons.data_object,
                onPressed: lookup != null && lookup.found ? () => _copy(context, lookup.toJsonText()) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
