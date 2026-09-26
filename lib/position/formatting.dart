import 'dart:io';

/// 与 C# `double.ToString(CultureInfo.InvariantCulture)` 一致的最短表示：整数不带 `.0`。
String formatNumber(num value) {
  if (value is int) return value.toString();
  final d = value.toDouble();
  if (d.isFinite && d == d.truncateToDouble() && d.abs() < 1e15) return d.toInt().toString();
  return d.toString();
}

/// C# `"0.########"`：最多 8 位小数，去掉末尾的 0。
String formatUpTo8(double value) {
  var text = value.toStringAsFixed(8);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return text == '-0' ? '0' : text;
}

/// 坐标显示格式，照搬 `CoordinateFormatter.Format`：整数部分左侧补齐 4 位，小数最多 5 位并右侧补空格，
/// 配合等宽字体让数字对齐。
String formatCoordinate(double value) {
  final text = value.toStringAsFixed(5);
  final dot = text.indexOf('.');
  if (dot < 0) return text.padLeft(10);
  final integerPart = text.substring(0, dot).padLeft(4);
  final fractionPart = text.substring(dot + 1).replaceFirst(RegExp(r'0+$'), '').padRight(5);
  return '$integerPart.$fractionPart';
}

/// 与 C# `Environment.NewLine` 一致。
String get platformNewLine => Platform.isWindows ? '\r\n' : '\n';

/// token 仅显示首尾 4 位。
String maskToken(String token) {
  final trimmed = token.trim();
  if (trimmed.length <= 8) return '***';
  return '${trimmed.substring(0, 4)}...${trimmed.substring(trimmed.length - 4)}';
}
