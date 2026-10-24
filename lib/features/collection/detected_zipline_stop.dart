import 'package:zipliner_client/shared/formatting/coordinates.dart';

class DetectedZiplineStop {
  const DetectedZiplineStop({
    required this.order,
    required this.x,
    required this.y,
    required this.z,
    required this.direction,
    required this.distance,
    required this.heightOffset,
    this.connectToPrevious = true,
  });

  final int order;
  final int x;
  final double y;
  final int z;
  final String direction;
  final double distance;
  final double heightOffset;

  /// 与上一个识别到的滑索之间没有落地，导出时连成同一路线。
  final bool connectToPrevious;

  String get label => '($x,${formatNumber(y)},$z,$direction)';
}
