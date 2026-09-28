import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tf_framework/tf_framework.dart';

import 'follow_placement.dart';

typedef TargetCoordinate = ({double x, double y, double z});

/// 持久化的用户选项，存放在框架的偏好设置里。对应原工具的 `settings.json`。
abstract final class PositionPrefs {
  static const requestPolling = TfPreferenceKey<bool>('position.requestPolling', defaultValue: false);
  static const requestIntervalSeconds = TfPreferenceKey<double>(
    'position.requestIntervalSeconds',
    defaultValue: 3,
    validator: _validRequestInterval,
  );
  static bool _validRequestInterval(double value) => value >= 0.2 && value <= 10;

  /// 升级时保留旧版离散档位的选择。
  static Future<void> migrateRequestSpeed(TfPreferencesController prefs) async {
    const legacy = TfPreferenceKey<int>('position.requestSeconds', defaultValue: 0);
    if (!prefs.isCustomized(legacy)) return;
    final seconds = prefs.get(legacy);
    if (const [1, 3, 5, 10].contains(seconds)) {
      if (!prefs.isCustomized(requestIntervalSeconds)) await prefs.set(requestIntervalSeconds, seconds.toDouble());
      if (!prefs.isCustomized(requestPolling)) await prefs.set(requestPolling, true);
    }
    await prefs.reset(legacy);
  }

  static const followGame = TfPreferenceKey<bool>('position.followGame', defaultValue: false);
  static const followPosition = TfPreferenceKey<String>('position.followPosition', defaultValue: 'top');

  /// `{"top":{"h":0,"v":0},...}`，每个显示位置单独保存偏移。
  static const followOffsets = TfPreferenceKey<String>('position.followOffsets', defaultValue: '{}');

  /// `usbHidUsage|按键名`，默认 F12。
  static final hotkey = TfPreferenceKey<String>(
    'position.hotkey',
    defaultValue: '${PhysicalKeyboardKey.f12.usbHidUsage}|F12',
  );
  static const recordCapture = TfPreferenceKey<bool>('position.recordCapture', defaultValue: kDebugMode);
  static const selectedRole = TfPreferenceKey<String>('position.selectedRole', defaultValue: '');

  /// Android：连接期间保持屏幕常亮，方便把手机当副屏看坐标。
  static const keepScreenOn = TfPreferenceKey<bool>('position.keepScreenOn', defaultValue: true);

  /// 是否已经看过“坐标窗口怎么返回”的说明。
  static const overlayHintShown = TfPreferenceKey<bool>('position.overlayHintShown', defaultValue: false);

  static const overlayScale = TfPreferenceKey<double>(
    'position.overlay.scale',
    defaultValue: 1,
    validator: _validOverlayScale,
  );
  static const overlayDecimals = TfPreferenceKey<int>(
    'position.overlay.decimals',
    defaultValue: 3,
    validator: _validOverlayDecimals,
  );

  /// 用户手动指定的导航目标；关闭时保留坐标，方便下次继续使用。
  static const targetEnabled = TfPreferenceKey<bool>('position.target.enabled', defaultValue: false);
  static const targetX = TfPreferenceKey<double>(
    'position.target.x',
    defaultValue: 0,
    validator: _validTargetCoordinate,
  );
  static const targetY = TfPreferenceKey<double>(
    'position.target.y',
    defaultValue: 0,
    validator: _validTargetCoordinate,
  );
  static const targetZ = TfPreferenceKey<double>(
    'position.target.z',
    defaultValue: 0,
    validator: _validTargetCoordinate,
  );

  static bool _validOverlayScale(double value) => const [1.0, 1.2, 1.4].contains(value);
  static bool _validOverlayDecimals(int value) => const [0, 3, 5].contains(value);
  static bool _validTargetCoordinate(double value) => value.isFinite;

  static TargetCoordinate? target(TfPreferencesController prefs) {
    if (!prefs.get(targetEnabled)) return null;
    return (x: prefs.get(targetX), y: prefs.get(targetY), z: prefs.get(targetZ));
  }

  static Future<void> setTarget(TfPreferencesController prefs, TargetCoordinate target) async {
    await prefs.set(targetX, target.x);
    await prefs.set(targetY, target.y);
    await prefs.set(targetZ, target.z);
    await prefs.set(targetEnabled, true);
  }

  static Future<void> clearTarget(TfPreferencesController prefs) => prefs.set(targetEnabled, false);

  static FollowPosition position(TfPreferencesController prefs) => FollowPosition.parse(prefs.get(followPosition));

  static ({double h, double v}) offset(TfPreferencesController prefs, FollowPosition position) {
    final all = _offsets(prefs);
    final entry = all[position.name];
    if (entry is! Map) return (h: 0, v: 0);
    double read(Object? v) => v is num ? v.toDouble() : 0;
    return (h: read(entry['h']), v: read(entry['v']));
  }

  static Future<void> setOffset(TfPreferencesController prefs, FollowPosition position, {double? h, double? v}) {
    final all = _offsets(prefs);
    final current = offset(prefs, position);
    all[position.name] = {'h': h ?? current.h, 'v': v ?? current.v};
    return prefs.set(followOffsets, jsonEncode(all));
  }

  static Map<String, dynamic> _offsets(TfPreferencesController prefs) {
    try {
      final decoded = jsonDecode(prefs.get(followOffsets));
      return decoded is Map ? decoded.cast<String, dynamic>() : {};
    } on FormatException {
      return {};
    }
  }

  static ({PhysicalKeyboardKey key, String label}) hotkeyOf(TfPreferencesController prefs) {
    final parts = prefs.get(hotkey).split('|');
    final usage = int.tryParse(parts.first);
    final key = usage == null ? null : PhysicalKeyboardKey.findKeyByCode(usage);
    if (key == null) return (key: PhysicalKeyboardKey.f12, label: 'F12');
    return (key: key, label: parts.length > 1 && parts[1].isNotEmpty ? parts[1] : 'F12');
  }

  static Future<void> setHotkey(TfPreferencesController prefs, PhysicalKeyboardKey key, String label) =>
      prefs.set(hotkey, '${key.usbHidUsage}|$label');
}
