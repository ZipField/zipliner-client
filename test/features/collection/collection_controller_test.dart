import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/features/collection/collection_controller.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

const role = RoleSession(
  tokenId: 'local',
  region: SklandRegion.skland,
  binding: RoleBinding(serverId: '1', roleId: 'role'),
);

void main() {
  test(
    'capture started before coordinates loads marks when a map arrives',
    () async {
      var context = const CollectionContext(revision: 1);
      var requests = 0;
      final controller = CollectionController(
        readContext: () => context,
        loadMarks: (selectedRole, map) async {
          expect(selectedRole, role);
          expect(map, 'map01');
          requests++;
          return [const ZiplineMark(0, 10, 0)];
        },
        captureDirectory: () async => '.',
        setWarning: (_) {},
        onChanged: () {},
      );
      addTearDown(controller.dispose);
      await controller.startCapture();
      expect(requests, 0);
      context = const CollectionContext(
        revision: 1,
        role: role,
        mapId: 'map01',
        position: PositionSnapshot(1, 13.5, 1),
      );
      controller.acceptPosition(context.position!);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
      expect(controller.detector, isNotNull);
      controller.acceptPosition(context.position!);
      controller.acceptPosition(context.position!);
      expect(controller.hasDetections, isTrue);
      controller.stopCapture();
      expect(controller.isCapturing, isFalse);
    },
  );

  test('a late marks response from a retired connection cannot replace capture data', () async {
    var context = const CollectionContext(
      revision: 1,
      role: role,
      mapId: 'map01',
      position: PositionSnapshot(1, 13.5, 1),
    );
    final marks = Completer<List<ZiplineMark>>();
    final controller = CollectionController(
      readContext: () => context,
      loadMarks: (_, _) => marks.future,
      captureDirectory: () async => '.',
      setWarning: (_) {},
      onChanged: () {},
    );
    addTearDown(controller.dispose);
    final pending = controller.startCapture();
    context = const CollectionContext(revision: 2);
    controller.clearMap(resetAttempt: true);
    marks.complete([const ZiplineMark(0, 10, 0)]);
    await pending;
    expect(controller.captureMarks, isNull);
    expect(controller.detector, isNull);
  });
}
