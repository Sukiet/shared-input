import 'package:flutter/material.dart';
import 'audio_sync_mode.dart';

class AudioOutputInfo {
  const AudioOutputInfo({
    this.status = 'loading',
    this.name = '',
    this.id = '',
    this.error = '',
    this.automatic = false,
    this.revision = -1,
    this.kind = 'unknown',
    this.headphones = false,
  });
  final String status, name, id, error;
  final bool automatic;
  final int revision;
  final String kind;
  final bool headphones;

  factory AudioOutputInfo.fromMap(Map<String, dynamic> data) => AudioOutputInfo(
    status: switch (data['status']) {
      'ready' => 'ready',
      'none' => 'none',
      'loading' => 'loading',
      _ => 'error',
    },
    name: data['name'] is String ? data['name'] as String : '',
    id: data['id'] is String ? data['id'] as String : '',
    error: data['error'] is String ? data['error'] as String : '',
    automatic: data['automatic'] == true,
    revision: data['revision'] is int ? data['revision'] as int : 0,
    kind: data['kind'] is String ? data['kind'] as String : 'unknown',
    headphones: data['headphones'] == true,
  );

  String get label => switch (status) {
    'ready' => name.isEmpty ? '音频输出设备（名称不可用）' : name,
    'none' => '未检测到音频输出设备',
    'loading' => '正在识别输出设备…',
    _ => '无法读取音频输出设备',
  };
  String get hint => status == 'error'
      ? '点击刷新重试${error.isEmpty ? '' : ' · $error'}'
      : automatic
      ? '系统默认输出 · 设备切换后自动更新'
      : '系统默认输出 · 可手动刷新';
}

class AudioOutputPanel extends StatelessWidget {
  const AudioOutputPanel({
    super.key,
    required this.info,
    required this.onRefresh,
    this.mode = AudioSyncMode.off,
    this.onModeChanged,
    this.syncStatus = '不同步',
    this.onRetry,
    this.bufferMs = 40,
    this.onBufferChanged,
    this.onBufferChangeEnd,
  });
  final AudioOutputInfo info;
  final VoidCallback onRefresh;
  final AudioSyncMode mode;
  final ValueChanged<AudioSyncMode>? onModeChanged;
  final String syncStatus;
  final VoidCallback? onRetry;
  final int bufferMs;
  final ValueChanged<int>? onBufferChanged, onBufferChangeEnd;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('audio-output-panel'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(
            Icons.volume_up_outlined,
            size: 19,
            color: Color(0xff99b8d8),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('音频输出', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            key: const Key('refresh-audio-output'),
            tooltip: '刷新输出设备',
            onPressed: onRefresh,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        info.label,
        key: const Key('audio-output-name'),
        style: const TextStyle(fontSize: 13),
      ),
      const SizedBox(height: 4),
      Text(
        info.hint,
        style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<AudioSyncMode>(
        key: const Key('audio-sync-mode'),
        initialValue: mode,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '音频同步'),
        items: [
          for (final item in AudioSyncMode.values)
            DropdownMenuItem(value: item, child: Text(item.label)),
        ],
        onChanged: onModeChanged == null
            ? null
            : (value) {
                if (value != null) onModeChanged!(value);
              },
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          const Expanded(child: Text('播放缓冲', style: TextStyle(fontSize: 12))),
          Text(
            '$bufferMs ms',
            key: const Key('audio-buffer-value'),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      Slider(
        key: const Key('audio-buffer-slider'),
        value: bufferMs.clamp(10, 200).toDouble(),
        min: 10,
        max: 200,
        divisions: 190,
        label: '$bufferMs ms',
        onChanged: onBufferChanged == null
            ? null
            : (value) => onBufferChanged!(value.round()),
        onChangeEnd: onBufferChangeEnd == null
            ? null
            : (value) => onBufferChangeEnd!(value.round()),
      ),
      const Text(
        '越小延迟越低，越大越稳定；松开滑杆后生效。',
        style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
      ),
      const SizedBox(height: 6),
      Text(
        syncStatus,
        style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
      ),
      if (onRetry != null)
        TextButton(onPressed: onRetry, child: const Text('重试音频同步')),
    ],
  );
}
