/// 坐标显示格式，照搬 `CoordinateFormatter.Format`：整数部分左侧补齐 4 位，小数最多 5 位并右侧补空格，
/// 配合等宽字体让数字对齐。
String formatCoordinate(double value) {
  final text = value.toStringAsFixed(5);
  final dot = text.indexOf('.');
  if (dot < 0) return text.padLeft(10);
  final integerPart = text.substring(0, dot).padLeft(4);
  final fractionPart = text
      .substring(dot + 1)
      .replaceFirst(RegExp(r'0+$'), '')
      .padRight(5);
  return '$integerPart.$fractionPart';
}

/// token 仅显示首尾 4 位。
String maskToken(String token) {
  final trimmed = token.trim();
  if (trimmed.length <= 8) return '***';
  return '${trimmed.substring(0, 4)}...${trimmed.substring(trimmed.length - 4)}';
}

/// 主页读数不需要原工具的对齐空格，只保留最多 5 位小数。
String formatUpTo5(double value) =>
    formatCoordinate(value).trim().replaceFirst(RegExp(r'\.$'), '');
