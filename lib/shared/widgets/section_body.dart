import 'package:flutter/widgets.dart';

/// `TfSection` 里除了 `TfListTile` 以外的内容（文本、按钮组、输入框等）。
/// 框架的分组容器不给子组件加内边距，也不拉伸宽度；这里补上与列表项一致的边距并左对齐。
class SectionBody extends StatelessWidget {
  const SectionBody({super.key, required this.child, this.vertical = 12});

  final Widget child;
  final double vertical;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: vertical),
      child: Align(alignment: AlignmentDirectional.centerStart, child: child),
    ),
  );
}
