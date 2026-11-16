import 'package:flutter/material.dart';
import 'local_key.dart';

class LocalKeyPanel extends StatelessWidget {
  const LocalKeyPanel({
    super.key,
    required this.keys,
    required this.enabled,
    required this.onAdd,
    required this.onRemove,
  });
  final List<LocalKeyException> keys;
  final bool enabled;
  final VoidCallback onAdd;
  final ValueChanged<LocalKeyException> onRemove;
  @override
  Widget build(BuildContext context) => Column(
    key: const Key('local-key-panel'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              '留在 Windows 的按键',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton.icon(
            key: const Key('add-local-key'),
            onPressed: enabled ? onAdd : null,
            icon: const Icon(Icons.add, size: 17),
            label: const Text('添加例外'),
          ),
        ],
      ),
      const Text(
        '后台控制时留在本机，不转发；旋钮的加、减分别添加。',
        style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
      ),
      if (keys.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            '暂无例外',
            style: TextStyle(fontSize: 12, color: Color(0xff929aa6)),
          ),
        ),
      if (keys.isNotEmpty)
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final key in keys)
              Tooltip(
                message: '${key.label} · ${key.code}',
                child: InputChip(
                  key: ValueKey('local-key-${key.key}'),
                  label: Text(key.label),
                  onDeleted: enabled ? () => onRemove(key) : null,
                  deleteButtonTooltipMessage: '移除例外',
                ),
              ),
          ],
        ),
    ],
  );
}
