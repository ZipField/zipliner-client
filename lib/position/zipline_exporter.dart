import 'formatting.dart';
import 'zipline_realtime_detector.dart';

/// 照搬 `ZiplineCollectionExporter`：把识别结果导出为 Zipliner 编辑器可导入的滑索与路线 JSON。
abstract final class ZiplineCollectionExporter {
  static String exportMarksJson(List<DetectedZiplineStop> stops) =>
      '[${_buildNodes(stops).map(_formatNode).join(',')}]';

  static String exportRoutesJson(List<DetectedZiplineStop> stops) =>
      '[${_connectedGroups(_buildNodes(stops)).map(_formatRoute).join(',')}]';

  static List<_Node> _buildNodes(List<DetectedZiplineStop> stops) {
    final nodes = <_Node>[];
    final byId = <String, _Node>{};
    _Node? previous;
    for (final stop in stops) {
      final id = '(${stop.x},${stop.z})';
      final node = byId.putIfAbsent(id, () {
        final created = _Node(id, stop);
        nodes.add(created);
        return created;
      });
      if (previous != null && stop.connectToPrevious && previous.id != node.id) {
        previous.connect.add(node.id);
        node.connect.add(previous.id);
      }
      previous = node;
    }
    return nodes;
  }

  static List<List<_Node>> _connectedGroups(List<_Node> nodes) {
    final result = <List<_Node>>[];
    final visited = <String>{};
    final byId = {for (final node in nodes) node.id: node};
    for (final node in nodes) {
      if (visited.contains(node.id)) continue;
      final group = <_Node>[];
      final stack = <_Node>[node];
      visited.add(node.id);
      while (stack.isNotEmpty) {
        final current = stack.removeLast();
        group.add(current);
        for (final id in current.connect) {
          final next = byId[id];
          if (next != null && visited.add(id)) stack.add(next);
        }
      }
      group.sort((a, b) => a.firstOrder.compareTo(b.firstOrder));
      result.add(group);
    }
    return result;
  }

  static String _formatNode(_Node node) {
    final connect = (node.connect.toList()..sort()).map((id) => '"$id"').join(',');
    return '{"id":"${node.id}","name":"未命名滑索","connect":[$connect],"h":${_formatHeight(node.stop.y)},"direction":"${node.stop.direction}"}';
  }

  static String _formatRoute(List<_Node> nodes) =>
      '{"name":"未命名路线","marks":[${nodes.map((node) => '"${node.id}"').join(',')}]}';

  static String _formatHeight(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.000001) return rounded.toInt().toString();
    return formatUpTo8(value);
  }
}

class _Node {
  _Node(this.id, this.stop) : firstOrder = stop.order;

  final String id;
  final DetectedZiplineStop stop;
  final int firstOrder;
  final Set<String> connect = {};
}
