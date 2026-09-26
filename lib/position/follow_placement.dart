import 'dart:ui';

/// 坐标窗跟随游戏窗口时的显示位置，文字与原工具一致。
enum FollowPosition {
  top('正上'),
  topRight('右上'),
  right('正右'),
  bottomRight('右下'),
  bottom('正下'),
  bottomLeft('左下'),
  left('正左'),
  topLeft('左上');

  const FollowPosition(this.label);

  final String label;

  static FollowPosition parse(String value) =>
      values.firstWhere((p) => p.name == value || p.label == value, orElse: () => top);

  /// 正上/正下时水平偏移可以为负（向左），正左/正右时垂直偏移可以为负。
  bool get allowsNegativeHorizontal => this == top || this == bottom;

  bool get allowsNegativeVertical => this == left || this == right;
}

/// 照搬 `FollowWindowPlacement.Calculate`，返回坐标窗左上角。
abstract final class FollowWindowPlacement {
  static const baseMargin = 8.0;

  static Offset calculate(Rect game, Size window, FollowPosition position, double horizontal, double vertical) {
    final centeredLeft = game.left + (game.width - window.width) / 2;
    final centeredTop = game.top + (game.height - window.height) / 2;
    final leftAligned = game.left + baseMargin + horizontal;
    final rightAligned = game.right - window.width - baseMargin - horizontal;
    final (left, top) = switch (position) {
      FollowPosition.topLeft => (leftAligned, game.top + baseMargin + vertical),
      FollowPosition.topRight => (rightAligned, game.top + baseMargin + vertical),
      FollowPosition.left => (leftAligned, centeredTop + vertical),
      FollowPosition.right => (rightAligned, centeredTop + vertical),
      // 原实现左下比右下多留 30，保持一致。
      FollowPosition.bottomLeft => (leftAligned, game.bottom - window.height - baseMargin - 30 - vertical),
      FollowPosition.bottomRight => (rightAligned, game.bottom - window.height - baseMargin - vertical),
      FollowPosition.bottom => (centeredLeft + horizontal, game.bottom - window.height - baseMargin - vertical),
      FollowPosition.top => (centeredLeft + horizontal, game.top + baseMargin + vertical),
    };
    return Offset(_round4(left), _round4(top));
  }

  static double _round4(double v) => (v * 10000).roundToDouble() / 10000;
}
