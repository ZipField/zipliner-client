import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/network/network_helper_bridge.dart';
import 'package:zipliner_client/network/weak_network_controller.dart';

class FakeHelper implements NetworkHelperBridge {
  final messages = <Map<String, dynamic>>[];
  final pipe = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  bool closed = false;
  @override
  Stream<Map<String, dynamic>> get events => pipe.stream;
  @override
  Future<void> start() async {}
  @override
  void send(Map<String, dynamic> command) => messages.add(command);
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await pipe.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('enable configures helper; release is a snapshot command without an OFF window', () async {
    final helper = FakeHelper();
    final controller = WeakNetworkController(
      dataDirectory: '.',
      supported: true,
      helperFactory: () => helper,
    );
    expect(controller.enabled, isFalse);
    expect(controller.toggleHotkey.label, 'Ctrl+·');
    expect(controller.releaseHotkey.label, 'Ctrl+Tab');
    controller.updatePosition({'valid': true}, '坐标已连接');
    await controller.setEnabled(true, confirmRisk: () async => true);
    expect(helper.messages, [
      {
        'command': 'configure',
        'maximum': 20.0,
        'hotkeys': {
          'toggle': {'vk': 0xc0, 'modifiers': 1},
          'release': {'vk': 9, 'modifiers': 1},
        },
        'hotkeys_suspended': false,
        'hotkey_revision': 1,
      },
      {'command': 'enable', 'enabled': true, 'request_id': 1},
      {
        'command': 'position',
        'sample': {'valid': true},
      },
    ]);
    controller.releaseBacklog();
    expect(helper.messages.last, {'command': 'release_all'});
    expect(controller.enabled, isTrue);
    await controller.setEnabled(false);
    expect(helper.messages.last, {
      'command': 'enable',
      'enabled': false,
      'request_id': 2,
    });
    controller.dispose();
  });

  test(
    'duration and bindings persist without automatically enabling networking',
    () async {
      final fw = await TfFramework.initialize(
        designSystems: const [Material3DesignSystem()],
        store: TfMemoryPreferenceStore(),
      );
      final controller = WeakNetworkController(
        dataDirectory: '.',
        preferences: fw.preferences,
        supported: false,
      );
      await controller.setMaximum(15);
      expect(controller.maximum, 15);
      expect(controller.enabled, isFalse);
      await expectLater(
        controller.setHotkey(toggle: true, binding: controller.releaseHotkey),
        throwsArgumentError,
      );
      controller.dispose();
    },
  );
}
