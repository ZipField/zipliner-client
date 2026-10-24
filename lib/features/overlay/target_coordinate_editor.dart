import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/app/app_preferences.dart';
import 'package:zipliner_client/shared/formatting/coordinates.dart';

class TargetCoordinateEditor extends StatefulWidget {
  const TargetCoordinateEditor({super.key, required this.initial});

  final TargetCoordinate? initial;

  @override
  State<TargetCoordinateEditor> createState() => _TargetCoordinateEditorState();
}

class _TargetCoordinateEditorState extends State<TargetCoordinateEditor> {
  late final TextEditingController _x;
  late final TextEditingController _y;
  late final TextEditingController _z;
  String? _error;

  @override
  void initState() {
    super.initState();
    _x = TextEditingController(
      text: widget.initial == null ? '' : formatUpTo5(widget.initial!.x),
    );
    _y = TextEditingController(
      text: widget.initial == null ? '' : formatUpTo5(widget.initial!.y),
    );
    _z = TextEditingController(
      text: widget.initial == null ? '' : formatUpTo5(widget.initial!.z),
    );
  }

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    _z.dispose();
    super.dispose();
  }

  void _save() {
    final x = double.tryParse(_x.text.trim());
    final y = double.tryParse(_y.text.trim());
    final z = double.tryParse(_z.text.trim());
    if (x == null ||
        y == null ||
        z == null ||
        !x.isFinite ||
        !y.isFinite ||
        !z.isFinite) {
      setState(() => _error = 'X、Y、Z 都需要填写有效数字');
      return;
    }
    Navigator.of(context).pop((clear: false, x: x, y: y, z: z));
  }

  @override
  Widget build(BuildContext context) {
    Widget field(
      String label,
      TextEditingController controller, {
      TextInputAction? action,
      VoidCallback? submitted,
    }) => TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      textInputAction: action,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: submitted == null ? null : (_) => submitted(),
    );

    return SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('输入游戏内目标位置。保存后，坐标浮窗会实时计算当前位置到目标的三维直线距离。'),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: field('X', _x, action: TextInputAction.next)),
              const SizedBox(width: 8),
              Expanded(child: field('Y', _y, action: TextInputAction.next)),
              const SizedBox(width: 8),
              Expanded(
                child: field(
                  'Z',
                  _z,
                  action: TextInputAction.done,
                  submitted: _save,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              if (widget.initial != null)
                TfButton.secondary(
                  label: '清除目标',
                  onPressed: () =>
                      Navigator.of(context)
                          .pop((clear: true, x: 0.0, y: 0.0, z: 0.0)),
                ),
              TfButton(label: '保存', icon: Icons.check, onPressed: _save),
            ],
          ),
        ],
      ),
    );
  }
}
