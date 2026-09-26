import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 统一中文字体。Windows 默认用 Segoe UI 渲染拉丁字符、中文回退到雅黑，
/// 混排时粗细不一致；这里显式指定整套 CJK 字体。
abstract final class AppFonts {
  static String? get family {
    if (kIsWeb) return null;
    if (Platform.isWindows) return 'Microsoft YaHei UI';
    return null;
  }

  static List<String> get fallback {
    if (kIsWeb) return const [];
    if (Platform.isWindows) return const ['Microsoft YaHei', 'Segoe UI'];
    if (Platform.isLinux) {
      return const ['Noto Sans CJK SC', 'Noto Sans SC', 'Source Han Sans SC', 'WenQuanYi Micro Hei'];
    }
    return const [];
  }

  static const mono = 'Consolas';
  static const monoFallback = ['Cascadia Mono', 'DejaVu Sans Mono', 'Liberation Mono', 'monospace'];

  static TextStyle monoStyle(TextStyle? base) => (base ?? const TextStyle()).copyWith(
    fontFamily: mono,
    fontFamilyFallback: [...monoFallback, ...fallback],
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// 在框架生成的主题之上做的修正：字体统一，侧边导航栏标签使用正常字号。
ThemeData refineTheme(ThemeData theme) {
  TextTheme withFont(TextTheme t) => t.apply(fontFamily: AppFonts.family, fontFamilyFallback: AppFonts.fallback);
  final text = withFont(theme.textTheme);
  final scheme = theme.colorScheme;
  return theme.copyWith(
    textTheme: text,
    primaryTextTheme: withFont(theme.primaryTextTheme),
    navigationRailTheme: theme.navigationRailTheme.copyWith(
      selectedLabelTextStyle: text.labelLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
      minExtendedWidth: 220,
    ),
  );
}
