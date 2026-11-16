import 'package:flutter/material.dart';
import 'control_return_log.dart';

class ControlReturnLogPanel extends StatefulWidget {
  const ControlReturnLogPanel({
    super.key,
    required this.history,
    required this.onClear,
    required this.active,
  });
  final ControlReturnHistory history;
  final VoidCallback onClear;
  final bool active;

  @override
  State<ControlReturnLogPanel> createState() => _ControlReturnLogPanelState();
}

class _ControlReturnLogPanelState extends State<ControlReturnLogPanel> {
  ControlReturnType? _filter;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.history,
    builder: (context, _) {
      final all = widget.history.entries;
      final entries = all
          .where((e) => _filter == null || e.type == _filter)
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('断联日志', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.active ? '控制中' : 'Windows 本机输入',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff929aa6),
                  ),
                ),
              ),
              TextButton.icon(
                key: const Key('clear-return-logs'),
                onPressed: all.isEmpty ? null : widget.onClear,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('清除日志'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: const Key('return-log-filter'),
            initialValue: _filter?.name ?? 'all',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '日志类型'),
            items: [
              DropdownMenuItem(
                value: 'all',
                child: Text('全部类型 (${all.length})'),
              ),
              for (final type in ControlReturnType.values)
                DropdownMenuItem(
                  value: type.name,
                  child: Text(
                    '${type.label} (${all.where((e) => e.type == type).length})',
                  ),
                ),
            ],
            onChanged: (value) => setState(
              () => _filter = value == 'all' || value == null
                  ? null
                  : ControlReturnType.values.byName(value),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '每次返回 Windows 记录一条；正常切回也会记录。最近 300 条自动保存。',
            style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
          ),
          const SizedBox(height: 10),
          Container(
            height: 340,
            decoration: BoxDecoration(
              color: const Color(0xff101317),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xff303640)),
            ),
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      all.isEmpty ? '暂无返回记录' : '该类型暂无记录',
                      style: const TextStyle(color: Color(0xff929aa6)),
                    ),
                  )
                : ListView.separated(
                    key: const Key('return-log-list'),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) => _entry(entries[index]),
                  ),
          ),
        ],
      );
    },
  );

  Widget _entry(ControlReturnEntry entry) {
    final time = entry.time.toLocal();
    String pad(int n, [int digits = 2]) => n.toString().padLeft(digits, '0');
    final stamp =
        '${time.year}-${pad(time.month)}-${pad(time.day)} '
        '${pad(time.hour)}:${pad(time.minute)}:${pad(time.second)}.${pad(time.millisecond, 3)}';
    final duration = entry.durationMs < 1000
        ? '${entry.durationMs} ms'
        : '${(entry.durationMs / 1000).toStringAsFixed(1)} s';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                stamp,
                style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
              ),
              Text(
                entry.type.label,
                style: const TextStyle(fontSize: 11, color: Color(0xff99b8d8)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(entry.title, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 4),
          Text(
            '${entry.mode.label} · ${entry.connectionLabel} · 持续 $duration',
            style: const TextStyle(fontSize: 11, color: Color(0xffb6bec9)),
          ),
          if (entry.detail?.isNotEmpty == true) ...[
            const SizedBox(height: 4),
            Text(entry.detail!, style: const TextStyle(fontSize: 11)),
          ],
          const SizedBox(height: 4),
          SelectableText(
            '原因代码：${entry.reasonLabel}',
            style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
          ),
          if (entry.exitDiagnostics.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              entry.diagnosticsSummary,
              style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
            ),
          ],
        ],
      ),
    );
  }
}
