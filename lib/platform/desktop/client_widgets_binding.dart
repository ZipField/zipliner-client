import 'dart:io';

import 'package:flutter/widgets.dart';

/// Work around the Windows accessibility bridge crash in the current engine.
///
/// Symbolicating the 3.47.0 release DLL maps the startup access violation to
/// AccessibilityBridge::CreateRemoveReparentedNodesUpdate (+0xba). See
/// https://github.com/flutter/flutter/issues/175041.
///
/// Do not create a Windows semantics tree: Dart exception handlers cannot catch
/// this native crash. This also covers the independent overlay process because
/// both entry points initialize this binding in main(). Mouse, keyboard, focus,
/// and other platforms retain their normal behavior; Windows screen readers
/// temporarily cannot inspect the app's controls. Remove this workaround after
/// upgrading to an engine with a verified fix for that bridge.
class ClientWidgetsBinding extends WidgetsFlutterBinding {
  @override
  bool get semanticsEnabled => !Platform.isWindows && super.semanticsEnabled;
}
