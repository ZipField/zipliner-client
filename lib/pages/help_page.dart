import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_info.dart';
import '../ui/section_body.dart';

class _Faq {
  const _Faq(this.question, this.answer);

  final String question;
  final String answer;
}

const _gettingStarted = [
  _Faq(
    '第 1 步：选择账号模式',
    '登录 Zipliner 后可管理网站上的绑定账号，并与网站共享实时位置。也可使用本地模式，在本机登录森空岛 / SKPort。旧版账号会自动迁入本地游客档案。',
  ),
  _Faq(
    '第 2 步：打开位置同步',
    '森空岛只会给打开了“位置同步”的角色下发坐标。工具检测到没有打开时会提示你，点“同意并连接”即可一键开启；'
        '也可以在森空岛 App → 终末地 → 地图工具，右下角打开“位置同步”。',
  ),
  _Faq('第 3 步：进入游戏', '进入游戏并登录对应角色，坐标会自动出现。角色不在线时工具会每隔一会儿自动重试，不用手动操作。'),
];

const _faqs = [
  _Faq(
    '一直显示“没有收到坐标”怎么办？',
    '1. 确认已经进入游戏，并且登录的是上面“角色”一栏里的那个角色；\n'
        '2. 打开森空岛 App 的地图工具，确认能看到自己的位置；\n'
        '3. 有多个角色时，点“角色”一栏切换到正确的角色。',
  ),
  _Faq(
    '提示“登录已失效”怎么办？',
    '森空岛的登录会过期，修改密码后也会失效。打开“账号管理”，在对应账号上点“重新登录”即可，其他设置不会丢失。',
  ),
  _Faq(
    '坐标窗口怎么用？',
    '在“坐标显示”里点“打开”，会打开独立的坐标窗，主界面仍保留在任务栏。默认按 F12 显示或隐藏坐标窗；未跟随游戏时可以拖动坐标窗调整位置。',
  ),
  _Faq(
    '“跟随游戏窗口”是什么？',
    '开启后坐标窗会贴在游戏窗口的指定位置，背景透明、鼠标可以穿透，不会挡住游戏操作。'
        '此时只能用快捷键回到主界面；如果没有找到游戏窗口，坐标窗会保持可点击。\n'
        '该功能只读取 endfield.exe 的窗口位置，不读取游戏内存、不注入、不向游戏发送任何输入。',
  ),
  _Faq(
    '快捷键按了没反应？',
    '换一个不常用的键（例如 F10、F12、Insert）试试；如果还是不行，可以尝试右键本工具“以管理员身份运行”。',
  ),
  _Faq('“获取当前滑索”找不到？', '站在滑索正中间附近（3 米以内）再试。刚放置的滑索需要过一小会森空岛才能查到。'),
  _Faq(
    '采集的数据保存在哪里？',
    '“设置 → 打开数据文件夹”。每次采集会新建一个 zipline-日期-时间 文件夹，里面是 positions、marks、detections 三个 CSV 文件。',
  ),
  _Faq(
    '会不会盗号 / 被封？',
    '本地游客与本机直连凭据使用系统安全存储，不会自动上传。Zipliner 模式的账号绑定保存在 Zipliner 后端，实时位置通过其定位服务共享。'
        '弱网功能有独立的风险提示，请确认后再使用。源码以 GPL-3.0 协议开源，可以自行查看。',
  ),
  _Faq(
    'Windows 提示“已保护你的电脑”？',
    '本工具没有购买代码签名证书，Windows 会拦截未签名的程序。点“更多信息”→“仍要运行”即可。',
  ),
  _Faq('打不开、闪退或者有其他问题？', '到“设置 → 复制诊断信息”，然后在项目主页提交问题（Issue）并粘贴进去。诊断信息不包含账号凭据。'),
];

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) => TfScaffold(
    title: '使用帮助',
    body: TfListView(
      children: [
        _FaqSection(title: '快速开始', items: _gettingStarted),
        _FaqSection(title: '常见问题', items: _faqs),
        TfSection(
          title: '还有问题？',
          children: [
            TfListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('提交问题'),
              subtitle: const Text(AppInfo.issuesPage),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => launchUrl(Uri.parse(AppInfo.issuesPage)),
            ),
          ],
        ),
      ],
    ),
  );
}

class _FaqSection extends StatelessWidget {
  const _FaqSection({required this.title, required this.items});

  final String title;
  final List<_Faq> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TfSection(
      title: title,
      children: [
        for (final item in items)
          SectionBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text(item.question, style: theme.textTheme.titleSmall),
                Text(item.answer, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
      ],
    );
  }
}
