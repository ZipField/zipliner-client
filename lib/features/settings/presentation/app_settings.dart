import 'package:zipliner_client/app/app_scope.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zipliner_client/app/app_info.dart';
import 'package:zipliner_client/app/diagnostics.dart';
import 'package:zipliner_client/features/settings/presentation/help_page.dart';
import 'package:zipliner_client/features/maps/presentation/map_configuration_page.dart';
import 'package:zipliner_client/app/app_preferences.dart';

import 'package:zipliner_client/features/settings/presentation/update_prompt.dart';
import 'package:zipliner_client/platform/desktop/open_data_folder.dart';

List<TfSettingsSection> appSettings(BuildContext context) {
  final services = AppScope.of(context);
  final framework = TfFramework.of(context);
  final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  return [
    if (desktop)
      const TfSettingsSection(
        title: '坐标浮窗',
        footer: '外观跟随应用主题；在坐标页打开独立窗口，快捷键控制显示或隐藏。',
        settings: [
          TfChoiceSetting<double>(
            key: AppPreferences.overlayScale,
            title: '浮窗大小',
            options: [
              TfChoice(1.0, '小'),
              TfChoice(1.2, '中'),
              TfChoice(1.4, '大'),
            ],
          ),
          TfChoiceSetting<int>(
            key: AppPreferences.overlayDecimals,
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
            key: AppPreferences.keepScreenOn,
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
            onTap: (context) => openDataFolder(context, services.dataDirectory),
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
