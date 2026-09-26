import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 本地运行日志：内存里保留最近的记录，同时追加写入文件，供“复制诊断信息”使用。
///
/// 只记录状态与错误消息，不记录 token、密码、手机号等凭据。
class AppLog {
  AppLog._();

  static final instance = AppLog._();

  static const _maxLines = 300;
  static const _maxFileBytes = 1024 * 1024;

  final Queue<String> _lines = Queue();
  File? _file;

  String? get filePath => _file?.path;

  List<String> get lines => List.unmodifiable(_lines);

  /// 在 [directory] 下使用 `logs/app.log`，超过 1MB 时轮换为 `app.old.log`。
  void attachFile(String directory) {
    try {
      final dir = Directory('$directory${Platform.pathSeparator}logs')..createSync(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}app.log');
      if (file.existsSync() && file.lengthSync() > _maxFileBytes) {
        file.renameSync('${dir.path}${Platform.pathSeparator}app.old.log');
      }
      _file = File('${dir.path}${Platform.pathSeparator}app.log');
    } catch (_) {
      _file = null;
    }
  }

  void info(String message) => _add('INFO', message);

  void warn(String message) => _add('WARN', message);

  void error(String message, [Object? error, StackTrace? stack]) {
    final buffer = StringBuffer(message);
    if (error != null) buffer.write(': $error');
    if (stack != null) buffer.write('\n${stack.toString().split('\n').take(12).join('\n')}');
    _add('ERROR', buffer.toString());
  }

  void _add(String level, String message) {
    final line = '${DateTime.now().toIso8601String()} [$level] $message';
    _lines.addLast(line);
    while (_lines.length > _maxLines) {
      _lines.removeFirst();
    }
    if (kDebugMode) debugPrint(line);
    try {
      _file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // 日志写失败不影响功能。
    }
  }
}
