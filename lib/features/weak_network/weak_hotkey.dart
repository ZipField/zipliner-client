import 'package:flutter/services.dart';

import 'package:zipliner_client/platform/desktop/global_hotkey.dart';

class WeakHotkey {
  const WeakHotkey(this.key, this.modifiers, this.keyLabel);

  static final toggleDefault = WeakHotkey(
    PhysicalKeyboardKey.backquote,
    1,
    '·',
  );
  static final releaseDefault = WeakHotkey(PhysicalKeyboardKey.tab, 1, 'Tab');
  final PhysicalKeyboardKey key;
  // Ctrl, Alt, Shift, Win.
  final int modifiers;
  final String keyLabel;
  Map<String, int> get helperBinding => {
    'vk': GlobalHotkey.virtualKeyOf(key)!,
    'modifiers': modifiers,
  };
  String get encoded => '$modifiers|${key.usbHidUsage}|$keyLabel';
  String get label => [
    if ((modifiers & 1) != 0) 'Ctrl',
    if ((modifiers & 2) != 0) 'Alt',
    if ((modifiers & 4) != 0) 'Shift',
    if ((modifiers & 8) != 0) 'Win',
    keyLabel,
  ].join('+');

  bool sameChord(WeakHotkey other) =>
      key == other.key && modifiers == other.modifiers;

  static WeakHotkey decode(String? value, WeakHotkey fallback) {
    final parts = value?.split('|');
    if (parts == null || parts.length < 3) return fallback;
    final modifiers = int.tryParse(parts[0]);
    final usage = int.tryParse(parts[1]);
    if (modifiers == null || modifiers < 0 || modifiers > 15 || usage == null) {
      return fallback;
    }
    final key = PhysicalKeyboardKey(usage);
    if (!GlobalHotkey.supports(key)) return fallback;
    return WeakHotkey(key, modifiers, parts.sublist(2).join('|'));
  }

  static WeakHotkey? fromEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    final vk = GlobalHotkey.virtualKeyOf(event.physicalKey);
    if (vk == null || const {0x10, 0x11, 0x12, 0x5b, 0x5c}.contains(vk)) {
      return null;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifiers =
        (keyboard.isControlPressed ? 1 : 0) |
        (keyboard.isAltPressed ? 2 : 0) |
        (keyboard.isShiftPressed ? 4 : 0) |
        (keyboard.isMetaPressed ? 8 : 0);
    final label = event.physicalKey == PhysicalKeyboardKey.tab
        ? 'Tab'
        : event.logicalKey.keyLabel.isEmpty
        ? event.physicalKey.debugName ?? '按键'
        : event.logicalKey.keyLabel.toUpperCase();
    return WeakHotkey(event.physicalKey, modifiers, label);
  }
}

/// Shortcut capture state only. Windows input is read by the elevated helper.
class WeakHotkeys {
  bool _suspended = false;
  void Function()? onChanged;
  bool get suspended => _suspended;
  set suspended(bool value) {
    if (_suspended == value) return;
    _suspended = value;
    onChanged?.call();
  }

  void dispose() => onChanged = null;
}
