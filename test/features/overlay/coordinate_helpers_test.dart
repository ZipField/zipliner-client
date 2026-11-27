import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/features/overlay/follow_placement.dart';
import 'package:zipliner_client/shared/formatting/coordinates.dart';

void main() {
  group('formatting', () {
    test('坐标格式与原工具一致', () {
      expect(formatCoordinate(12.5), '  12.5    ');
      expect(formatCoordinate(3.0), '   3.     ');
      expect(formatCoordinate(-123.456789), '-123.45679');
    });

    test('数字格式', () {
      expect(maskToken('ABCDEFGHIJKL'), 'ABCD...IJKL');
      expect(maskToken('short'), '***');
    });
  });

  group('FollowWindowPlacement', () {
    const game = Rect.fromLTWH(100, 100, 1000, 600);
    const window = Size(200, 100);

    test('各显示位置', () {
      expect(
        FollowWindowPlacement.calculate(game, window, FollowPosition.top, 0, 0),
        const Offset(500, 108),
      );
      expect(
        FollowWindowPlacement.calculate(
          game,
          window,
          FollowPosition.bottomRight,
          10,
          20,
        ),
        const Offset(882, 572),
      );
      expect(
        FollowWindowPlacement.calculate(
          game,
          window,
          FollowPosition.bottomLeft,
          0,
          0,
        ),
        const Offset(108, 562),
      );
      expect(
        FollowWindowPlacement.calculate(
          game,
          window,
          FollowPosition.left,
          0,
          -50,
        ),
        const Offset(108, 300),
      );
    });
  });
}
