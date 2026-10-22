import 'account/account_gate.dart';

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_info.dart';
import 'core/app_log.dart';
import 'core/diagnostics.dart';
import 'core/services.dart';
import 'core/update_checker.dart';
import 'pages/help_page.dart';
import 'pages/map_configuration_page.dart';
import 'position/position_prefs.dart';
import 'ui/app_theme.dart';

/// 初始化框架与服务。和 [runApp] 分开，方便测试注入内存实现。
Future<(TfFramework, AppServices)> bootstrap() async {
  final watch = Stopwatch()..start();
  final framework = await TfFramework.initialize(
    designSystems: const [Material3DesignSystem(), LiquidGlassDesignSystem()],
    settingsBuilder: appSettings,
  );
  final dataDirectory = await AppServices.defaultDataDirectory();
  AppLog.instance
    ..attachFile(dataDirectory)
    ..info(
      '${AppInfo.name} ${AppInfo.version} 启动，${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
  final services = AppServices.create(
    framework.preferences,
    dataDirectory: dataDirectory,
    languageProvider: () =>
        apiLanguage(framework.preferences.get(TfPreferenceKeys.locale)),
  );
  try {
    if (Platform.isWindows || Platform.isLinux) {
      await windowManager.ensureInitialized();
      await windowManager.setTitle(AppInfo.name);
    }
  } catch (e, stack) {
    // 悬浮窗初始化失败不影响坐标同步本身。
    AppLog.instance.error('悬浮窗初始化失败', e, stack);
  }
  AppLog.instance.info('主界面基础初始化完成：${watch.elapsedMilliseconds} ms');
  return (framework, services);
}

List<TfSettingsSection> appSettings(BuildContext context) {
  final services = AppServices.of(context);
  final framework = TfFramework.of(context);
  final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  return [
    if (desktop)
      const TfSettingsSection(
        title: '坐标浮窗',
        footer: '外观跟随应用主题；在坐标页打开独立窗口，快捷键控制显示或隐藏。',
        settings: [
          TfChoiceSetting<double>(
            key: PositionPrefs.overlayScale,
            title: '浮窗大小',
            options: [
              TfChoice(1.0, '小'),
              TfChoice(1.2, '中'),
              TfChoice(1.4, '大'),
            ],
          ),
          TfChoiceSetting<int>(
            key: PositionPrefs.overlayDecimals,
            title: '小数位数',
            options: [
              TfChoice(0, '整数'),
              TfChoice(3, '3 位'),
              TfChoice(5, '5 位'),
            ],
          ),
        ],
      ),
    if (Platform.isAndroid)
      const TfSettingsSection(
        title: '坐标',
        settings: [
          TfToggleSetting(
            key: PositionPrefs.keepScreenOn,
            title: '连接时保持屏幕常亮',
            subtitle: '把手机放在旁边看坐标时不会自动锁屏',
            icon: Icons.light_mode_outlined,
          ),
        ],
      ),
    TfSettingsSection(
      title: '帮助与关于',
      footer: 'Zipliner 模式支持共享实时定位；本地模式直接连接森空岛 / SKPort。本软件以 GPL-3.0 协议开源。',
      settings: [
        TfNavigationSetting(
          title: '地图名称与高度配置',
          icon: Icons.map_outlined,
          builder: (_) => const MapConfigurationPage(),
        ),
        TfNavigationSetting(
          title: '使用帮助',
          icon: Icons.help_outline,
          builder: (_) => const HelpPage(),
        ),
        TfActionSetting(
          title: '检查更新',
          subtitle: services.updates.lastResult ?? '当前版本 ${AppInfo.version}',
          icon: Icons.system_update_alt,
          onTap: (context) => checkForUpdates(context, silent: false),
        ),
        if (desktop)
          TfActionSetting(
            title: '打开数据文件夹',
            subtitle: services.dataDirectory,
            icon: Icons.folder_open_outlined,
            onTap: (context) => _openFolder(context, services.dataDirectory),
          ),
        TfActionSetting(
          title: '复制诊断信息',
          subtitle: '反馈问题时附上，不包含账号凭据',
          icon: Icons.content_paste_go,
          onTap: (context) async {
            final text = await buildDiagnostics(services, framework);
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              showTfToast(context, '诊断信息已复制', type: TfToastType.success);
            }
          },
        ),
        TfActionSetting(
          title: '反馈问题',
          subtitle: AppInfo.issuesPage,
          icon: Icons.bug_report_outlined,
          onTap: (_) => launchUrl(Uri.parse(AppInfo.issuesPage)),
        ),
        TfActionSetting(
          title: '项目主页',
          subtitle: AppInfo.homepage,
          icon: Icons.code,
          onTap: (_) => launchUrl(Uri.parse(AppInfo.homepage)),
        ),
        const TfInfoSetting(
          title: '版本',
          value: AppInfo.version,
          icon: Icons.info_outline,
        ),
      ],
    ),
  ];
}

final _openingFolders = <String>{};
final _lastFolderRequests = <String, DateTime>{};

Future<void> _openFolder(BuildContext context, String path) async {
  final now = DateTime.now();
  final last = _lastFolderRequests[path];
  if (_openingFolders.contains(path) ||
      (last != null && now.difference(last) < const Duration(seconds: 1))) {
    return;
  }
  _openingFolders.add(path);
  _lastFolderRequests[path] = now;
  try {
    await Directory(path)
        .create(recursive: true)
        .timeout(const Duration(seconds: 5));
    if (Platform.isWindows) {
      // Launch Explorer asynchronously instead of calling ShellExecute through
      // url_launcher on the UI thread. Never wait for Explorer to exit.
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      await Process.start('$systemRoot\\explorer.exe', [
        Directory(path).absolute.path,
      ], mode: ProcessStartMode.detached).timeout(const Duration(seconds: 5));
    } else {
      final ok = await launchUrl(
        Uri.directory(path),
        mode: LaunchMode.externalApplication,
      ).timeout(const Duration(seconds: 5));
      if (!ok) throw StateError('文件夹未能打开');
    }
  } catch (error, stack) {
    AppLog.instance.error('打开数据文件夹失败', error, stack);
    if (!context.mounted) return;
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: path))
          .timeout(const Duration(seconds: 2));
      copied = true;
    } catch (_) {
      // Opening a folder must not leave the settings action waiting forever.
    }
    if (context.mounted) {
      showTfToast(
        context,
        copied ? '无法打开文件夹，路径已复制到剪贴板' : '无法打开文件夹，请按所示路径手动打开',
        type: TfToastType.warning,
      );
    }
  } finally {
    _openingFolders.remove(path);
  }
}

/// 检查更新；[silent] 为 true 时只在有新版本时提示。
Future<void> checkForUpdates(BuildContext context, {bool silent = true}) async {
  final updates = AppServices.of(context).updates;
  final info = await updates.check();
  if (!context.mounted) return;
  if (info == null) {
    if (!silent) showTfToast(context, updates.lastResult ?? '已是最新版本');
    return;
  }
  await presentUpdatePrompt(context, info, automatic: silent);
}

Future<void> presentUpdatePrompt(
  BuildContext context,
  UpdateInfo info, {
  bool automatic = false,
}) async {
  final services = AppServices.of(context);
  final updates = services.updates;
  if (updates.promptOpen ||
      (automatic &&
          (updates.lastPromptedVersion == info.version ||
              services.overlay?.active == true))) {
    return;
  }
  updates.promptOpen = true;
  updates.lastPromptedVersion = info.version;
  try {
    final open = await showTfConfirm(
      context,
      title: '发现新版本 ${info.version}',
      message:
          '当前版本 ${updates.currentVersion}。打开下载页面下载新版本后，解压覆盖旧文件即可，账号和设置都会保留。',
      confirmLabel: '去下载',
      cancelLabel: '以后再说',
    );
    if (open) await launchUrl(Uri.parse(info.url));
  } finally {
    updates.promptOpen = false;
  }
}

/// 把框架的语言偏好（空串表示跟随系统）转换成服务端 `X-Language` 的取值。
String apiLanguage(String preference) {
  final code = preference.isNotEmpty
      ? preference
      : PlatformDispatcher.instance.locale.languageCode;
  return switch (code) {
    'en' => 'en-US',
    _ => 'zh-CN',
  };
}

class ZiplinerApp extends StatelessWidget {
  const ZiplinerApp({
    super.key,
    required this.framework,
    required this.services,
  });

  final TfFramework framework;
  final AppServices services;

  @override
  Widget build(BuildContext context) => AppScope(
    services: services,
    child: TfApp(
      framework: framework,
      title: AppInfo.name,
      locale: const Locale('zh'),
      home: const AccountGate(),
      builder: (context, child) => Theme(
        data: refineTheme(Theme.of(context)),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}
