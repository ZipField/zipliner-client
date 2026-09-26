import 'api_client.dart';

/// 宽松的 JSON 读取：服务端部分数字字段在 OpenAPI 中声明为 `integer|string`，
/// 所以这里统一做类型容错，而不是在每个模型里重复判断。
extension JsonRead on Json {
  String str(String key, [String fallback = '']) {
    final value = this[key];
    if (value == null) return fallback;
    return value is String ? value : value.toString();
  }

  String? strOrNull(String key) {
    final value = this[key];
    if (value == null) return null;
    final text = value is String ? value : value.toString();
    return text.isEmpty ? null : text;
  }

  int integer(String key, [int fallback = 0]) => intOrNull(key) ?? fallback;

  int? intOrNull(String key) {
    final value = this[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? double.tryParse(value)?.toInt();
    return null;
  }

  double number(String key, [double fallback = 0]) {
    final value = this[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  bool boolean(String key, [bool fallback = false]) {
    final value = this[key];
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    if (value is num) return value != 0;
    return fallback;
  }

  Json obj(String key) => asJson(this[key]);

  List<Json> objects(String key) => asJsonList(this[key]);

  List<String> strings(String key) {
    final value = this[key];
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item != null) item.toString(),
    ];
  }

  /// ISO 字符串或 Unix 秒/毫秒都接受。
  DateTime? time(String key) => parseTime(this[key]);
}

Json asJson(Object? value) => value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};

List<Json> asJsonList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is Map) item.cast<String, dynamic>(),
      ]
    : const [];

DateTime? parseTime(Object? value) {
  if (value == null) return null;
  if (value is num) return _fromEpoch(value.toInt());
  final text = value.toString();
  if (text.isEmpty) return null;
  final asInt = int.tryParse(text);
  if (asInt != null) return _fromEpoch(asInt);
  return DateTime.tryParse(text)?.toLocal();
}

DateTime _fromEpoch(int value) =>
    // 10 位以内按秒，否则按毫秒。
    value < 100000000000
    ? DateTime.fromMillisecondsSinceEpoch(value * 1000)
    : DateTime.fromMillisecondsSinceEpoch(value);

/// 去掉值为 null 的键，用于构造请求体：服务端对部分 DTO 不接受显式 null。
Json compact(Map<String, Object?> map) => {
  for (final entry in map.entries)
    if (entry.value != null) entry.key: entry.value,
};
