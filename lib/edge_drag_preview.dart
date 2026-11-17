import 'package:flutter/material.dart';

class DragPreviewFile {
  const DragPreviewFile(this.name, this.path, this.promised);
  final String name, path;
  final bool promised;
}

class EdgeDragPreview {
  const EdgeDragPreview({
    this.enabled = false,
    this.hitEnabled = false,
    this.revision = -1,
    this.phase = 'off',
    this.files = const [],
    this.formats = const [],
    this.count = 0,
    this.truncated = false,
    this.message = '',
  });
  final bool enabled, hitEnabled, truncated;
  final int revision, count;
  final String phase, message;
  final List<DragPreviewFile> files;
  final List<String> formats;
  factory EdgeDragPreview.fromMap(Map<String, dynamic> value) =>
      EdgeDragPreview(
        enabled: value['enabled'] == true,
        hitEnabled: value['enabled'] == true && value['hitEnabled'] == true,
        revision: value['revision'] is int ? value['revision'] as int : 0,
        phase: value['phase'] is String ? value['phase'] as String : 'off',
        message: value['message'] is String ? value['message'] as String : '',
        count: value['count'] is int ? value['count'] as int : 0,
        truncated: value['truncated'] == true,
        formats: value['formats'] is List
            ? (value['formats'] as List).whereType<String>().take(32).toList()
            : [],
        files: value['files'] is List
            ? [
                for (final item in (value['files'] as List).take(256))
                  if (item is Map &&
                      item['name'] is String &&
                      item['path'] is String)
                    DragPreviewFile(
                      item['name'] as String,
                      item['path'] as String,
                      item['promised'] == true,
                    ),
              ]
            : [],
      );
  String get regionStatus => !enabled
      ? '区域关闭（测试未开启）'
      : hitEnabled
      ? '区域打开（1 像素命中）'
      : '区域关闭（鼠标穿透）';
  String get status => switch (phase) {
    'enter' => '已识别 $count 项${truncated ? '，显示前 ${files.length} 项' : ''}',
    'leave' => '拖拽已离开，保留识别结果',
    'drop' => '已松开，仅保留识别结果',
    'unsupported' => message.isEmpty ? '该对象没有可识别的文件列表' : message,
    'waiting' => '将文件拖到屏幕最外侧的 1 像素边缘（区域不可见）',
    _ => '未开启',
  };
}

class EdgeDragPreviewPanel extends StatelessWidget {
  const EdgeDragPreviewPanel({
    super.key,
    required this.preview,
    required this.edgeLabel,
    required this.canChange,
    required this.onChanged,
    required this.onClear,
  });
  final EdgeDragPreview preview;
  final String edgeLabel;
  final bool canChange;
  final ValueChanged<bool> onChanged;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) => Column(
    key: const Key('edge-drag-preview-panel'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SwitchListTile.adaptive(
        key: const Key('edge-drag-preview-toggle'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text(
          '边缘拖拽测试',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '$edgeLabel · 透明 1 像素 · 仅识别文件列表',
          style: const TextStyle(fontSize: 11),
        ),
        value: preview.enabled,
        onChanged: canChange ? onChanged : null,
      ),
      Row(
        children: [
          Icon(
            Icons.circle,
            size: 9,
            color: preview.enabled && preview.hitEnabled
                ? const Color(0xff6ee7b7)
                : const Color(0xff929aa6),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              preview.regionStatus,
              key: const Key('edge-drag-region-state'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: Text(
              preview.status,
              key: const Key('edge-drag-preview-status'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            key: const Key('clear-edge-drag-preview'),
            onPressed:
                canChange &&
                    (preview.files.isNotEmpty ||
                        preview.formats.isNotEmpty ||
                        preview.message.isNotEmpty)
                ? onClear
                : null,
            child: const Text('清空'),
          ),
        ],
      ),
      if (preview.enabled)
        const Text(
          '平时鼠标穿透，按住拖动时启用边缘命中；不复制或移动文件。',
          style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
        ),
      if (preview.files.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.builder(
            key: const Key('edge-drag-preview-files'),
            shrinkWrap: true,
            primary: false,
            itemCount: preview.files.length,
            itemBuilder: (_, index) {
              final file = preview.files[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${index + 1}. ${file.name}${file.promised ? '（待生成）' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (file.path.isNotEmpty)
                      SelectableText(
                        file.path,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xff929aa6),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      if (preview.formats.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '数据格式：${preview.formats.join('、')}',
            style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
          ),
        ),
    ],
  );
}
