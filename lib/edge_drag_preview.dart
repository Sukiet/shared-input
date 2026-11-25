import 'package:flutter/material.dart';

enum DragOrigin { controller, receiver }

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
    this.dragFlow = 0,
    this.dragStage = 'idle',
    this.gestureActive = false,
    this.onRemote = false,
    this.hovering = false,
    this.dragHistory = const [],
    this.dragReason = '',
    this.origin = DragOrigin.controller,
    this.side = '',
    this.sourcePress = 0,
    this.metadataPress = 0,
  });
  final bool enabled, hitEnabled, truncated;
  final int revision, count;
  final String phase, message;
  final List<DragPreviewFile> files;
  final List<String> formats;
  final int dragFlow;
  final int sourcePress, metadataPress;
  final String dragStage, dragReason;
  final bool gestureActive, onRemote, hovering;
  final List<String> dragHistory;
  final DragOrigin origin;
  final String side;
  String get originLabel =>
      origin == DragOrigin.controller ? '主控机拖拽事件' : '被控机拖拽事件';
  factory EdgeDragPreview.fromMap(Map<String, dynamic> value) =>
      EdgeDragPreview(
        enabled: value['enabled'] == true,
        origin: value['origin'] == 'receiver'
            ? DragOrigin.receiver
            : DragOrigin.controller,
        side: value['side'] as String? ?? '',
        sourcePress: value['sourcePress'] as int? ?? 0,
        metadataPress: value['metadataPress'] as int? ?? 0,
        hitEnabled: value['enabled'] == true && value['hitEnabled'] == true,
        revision: value['revision'] is int ? value['revision'] as int : 0,
        phase: value['phase'] is String ? value['phase'] as String : 'off',
        message: value['message'] is String ? value['message'] as String : '',
        count: value['count'] is int ? value['count'] as int : 0,
        truncated: value['truncated'] == true,
        dragFlow: value['dragFlow'] is int ? value['dragFlow'] as int : 0,
        dragStage: value['dragStage'] as String? ?? 'idle',
        gestureActive: value['gestureActive'] == true,
        onRemote: value['onRemote'] == true,
        hovering: value['hovering'] == true,
        dragReason: value['dragReason'] as String? ?? '',
        dragHistory: value['dragHistory'] is List
            ? (value['dragHistory'] as List)
                  .whereType<String>()
                  .take(16)
                  .toList()
            : [],
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
  static String stageLabel(String stage) => switch (stage) {
    'gesture' => '进入拖拽手势',
    'edge' => '屏幕边缘已接收',
    'switching' => '正在跨屏',
    'crossed' => '已跨机器',
    'ended' => '退出拖拽手势',
    'returned' => '回到原来的机器',
    'error' => '跨屏未完成',
    _ => '等待拖拽手势',
  };
  String get dragStatus =>
      '${stageLabel(dragStage)} · ${onRemote == (origin == DragOrigin.controller) ? 'Mac' : 'Windows'}';
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
    'closing' => '等待当前拖放结束后关闭区域',
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
    this.peer,
    this.syncStatus = '',
    this.canToggle = true,
  });
  final EdgeDragPreview preview;
  final String edgeLabel;
  final bool canChange;
  final ValueChanged<bool> onChanged;
  final VoidCallback onClear;
  final EdgeDragPreview? peer;
  final String syncStatus;
  final bool canToggle;
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
          '跨屏拖拽',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '$edgeLabel · 透明 1 像素${canToggle ? '' : ' · 开关由主控机同步'}',
          style: const TextStyle(fontSize: 11),
        ),
        value: preview.enabled,
        onChanged: canChange && canToggle ? onChanged : null,
      ),
      if (syncStatus.isNotEmpty)
        Text(
          syncStatus,
          style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
        ),
      Text(
        preview.originLabel,
        key: const Key('local-drag-origin'),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
      if (preview.enabled) ...[
        Text(
          preview.dragStatus,
          key: const Key('edge-drag-handoff-state'),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        if (preview.dragHistory.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5, bottom: 5),
            child: Text(
              preview.dragHistory.map(EdgeDragPreview.stageLabel).join(' → '),
              key: const Key('edge-drag-handoff-history'),
              style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
            ),
          ),
        if (preview.dragReason.isNotEmpty)
          Text(preview.dragReason, style: const TextStyle(fontSize: 11)),
      ],
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
                        preview.message.isNotEmpty ||
                        preview.dragHistory.isNotEmpty ||
                        (peer?.files.isNotEmpty ?? false) ||
                        (peer?.dragHistory.isNotEmpty ?? false))
                ? onClear
                : null,
            child: const Text('清空'),
          ),
        ],
      ),
      if (preview.enabled)
        const Text(
          'Windows 文件拖到 Mac 后松手复制，原文件保留；Mac → Windows 当前仍只显示拖拽信息。',
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
      if (peer case final other?) ...[
        const SizedBox(height: 12),
        Text(
          other.originLabel,
          key: const Key('peer-drag-origin'),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Text(
          other.dragStatus,
          key: const Key('peer-drag-state'),
          style: const TextStyle(fontSize: 13),
        ),
        if (other.dragHistory.isNotEmpty)
          Text(
            other.dragHistory.map(EdgeDragPreview.stageLabel).join(' → '),
            key: const Key('peer-drag-history'),
            style: const TextStyle(fontSize: 11),
          ),
        Text(
          '${other.origin == DragOrigin.receiver ? '被控机' : '主控机'}：${other.regionStatus}',
          style: const TextStyle(fontSize: 11),
        ),
        Text(
          other.status,
          key: const Key('peer-drag-files-status'),
          style: const TextStyle(fontSize: 12),
        ),
        if (other.files.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.builder(
              shrinkWrap: true,
              primary: false,
              itemCount: other.files.length,
              itemBuilder: (_, index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${index + 1}. ${other.files[index].name}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (other.files[index].path.isNotEmpty)
                      SelectableText(
                        other.files[index].path,
                        style: const TextStyle(fontSize: 11),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ],
  );
}
