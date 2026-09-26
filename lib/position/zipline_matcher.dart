import 'dart:math';

import '../skland/skland_models.dart';
import 'formatting.dart';

class ZiplineLookupResult {
  const ZiplineLookupResult._(this.found, this.x, this.y, this.z, this.direction, this.message);

  const ZiplineLookupResult.found(int x, double y, int z, String direction) : this._(true, x, y, z, direction, null);

  const ZiplineLookupResult.notFound() : this._(false, 0, 0, 0, null, '未找到，刚放置的滑索可能需要过一小会才能查找到');

  final bool found;
  final int x;
  final double y;
  final int z;
  final String? direction;
  final String? message;

  String toTupleText() => '($x,${formatNumber(y)},$z,$direction)';

  String toJsonText() => '{"x":$x,"y":${formatNumber(y)},"z":$z,"d":"$direction"}';
}

/// 标记点是滑索 3x3 占地的一个角，四个候选中心分别对应四个朝向。
class ZiplineCandidate {
  ZiplineCandidate(this.mark, this.centerX, this.centerZ, this.direction);

  final ZiplineMark mark;
  final double centerX;
  final double centerZ;
  final String direction;

  static List<ZiplineCandidate> fromMark(ZiplineMark mark) => [
    ZiplineCandidate(mark, mark.x + 1, mark.z + 1, '北'),
    ZiplineCandidate(mark, mark.x - 1, mark.z + 1, '西'),
    ZiplineCandidate(mark, mark.x - 1, mark.z - 1, '南'),
    ZiplineCandidate(mark, mark.x + 1, mark.z - 1, '东'),
  ];

  double planarDistance(PositionSnapshot position) {
    final dx = position.x - centerX;
    final dz = position.z - centerZ;
    return sqrt(dx * dx + dz * dz);
  }
}

/// 照搬 `ZiplineMatcher`：只比较水平距离，3 米内取最近。
abstract final class ZiplineMatcher {
  static const maxDistance = 3.0;

  static ZiplineLookupResult findNearest(PositionSnapshot? player, Iterable<ZiplineMark>? marks) {
    if (player == null || marks == null) return const ZiplineLookupResult.notFound();
    ZiplineCandidate? best;
    var bestDistance = double.infinity;
    for (final mark in marks) {
      for (final candidate in ZiplineCandidate.fromMark(mark)) {
        final distance = candidate.planarDistance(player);
        if (distance <= maxDistance && (best == null || distance < bestDistance)) {
          best = candidate;
          bestDistance = distance;
        }
      }
    }
    if (best == null) return const ZiplineLookupResult.notFound();
    return ZiplineLookupResult.found(best.centerX.floor(), best.mark.y, best.centerZ.floor(), best.direction);
  }
}
