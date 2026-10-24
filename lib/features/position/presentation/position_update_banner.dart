import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zipliner_client/features/settings/application/update_checker.dart';

class PositionUpdateBanner extends StatelessWidget {
  const PositionUpdateBanner({super.key, required this.update});

  final UpdateInfo update;

  @override
  Widget build(BuildContext context) => TfCard(
    child: Row(
      children: [
        const Icon(Icons.new_releases_outlined),
        const SizedBox(width: 12),
        Expanded(
          child: Text('发现新版本 ${update.version}，下载后解压覆盖旧文件即可，账号和设置都会保留。'),
        ),
        const SizedBox(width: 12),
        TfButton(
          label: '去下载',
          onPressed: () => launchUrl(Uri.parse(update.url)),
        ),
      ],
    ),
  );
}

/// 第一次打开、还没有账号时的上手引导。
