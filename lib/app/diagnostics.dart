import 'dart:io';

import 'package:tf_framework/tf_framework.dart';

import 'package:zipliner_client/app/app_info.dart';
import 'package:zipliner_client/shared/logging/app_log.dart';
import 'package:zipliner_client/app/app_services.dart';

/// 反馈问题时附带的诊断信息。只包含版本、系统、连接状态与日志，不包含 token、密码或手机号。
Future<String> buildDiagnostics(
  AppServices services,
  TfFramework framework,
) async {
  final monitor = services.monitor;
  final accounts = await services.tokens.list();
  final lines = <String>[
    '${AppInfo.name} ${AppInfo.version}',
    '系统：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    '语言：${Platform.localeName}',
    '组件库：${framework.activeDesignSystem.displayName}',
    '账号数：${accounts.length}，登录失败：${monitor.failedAccounts.length}',
    '状态：${monitor.status}${monitor.isError ? '（错误）' : ''}',
    '定位来源：${monitor.sourceLabel}，阶段：${monitor.phase.name}，更新序号：${monitor.positionRevision}',
    '最近坐标：${monitor.positionReceivedAt?.toIso8601String() ?? "无实时坐标"}',
    if (monitor.problem != null)
      '问题：${monitor.problem!.title} / ${monitor.problem!.raw}',
    '已连接：${monitor.isConnected}，地图：${monitor.mapId ?? '-'}，有坐标：${monitor.position != null}',
    '角色数：${monitor.roles.length}，采集中：${monitor.collection.isCapturing}',
    if (services.overlay != null)
      '悬浮窗：${services.overlay!.active ? '打开' : '关闭'}，跟随：${services.overlay!.follow}'
          '${services.overlay!.warning == null ? '' : '，${services.overlay!.warning}'}',
    '数据目录：${services.dataDirectory}',
    '',
    '最近日志：',
    ...AppLog.instance.lines.reversed.take(60).toList().reversed,
  ];
  return lines.join('\n');
}
