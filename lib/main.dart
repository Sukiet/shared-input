import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'pointer_preview.dart';
import 'sensitivity.dart';

void main() => runApp(const SharedInputApp());

class SharedInputApp extends StatelessWidget {
  const SharedInputApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Shared Input',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff99b8d8),
        brightness: Brightness.dark,
        surface: const Color(0xff191c21),
      ),
      scaffoldBackgroundColor: const Color(0xff14171b),
      useMaterial3: true,
      fontFamily: 'Microsoft YaHei',
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      ),
    ),
    home: const InputPage(),
  );
}

class InputPage extends StatefulWidget {
  const InputPage({super.key});
  @override
  State<InputPage> createState() => _InputPageState();
}

class _InputPageState extends State<InputPage>
    with SingleTickerProviderStateMixin {
  static const _channel = MethodChannel('shared_input/dry_run');
  final _position = ValueNotifier(const Offset(300, 120));
  final _stats = ValueNotifier<Map<String, dynamic>>({});
  final _speedText = TextEditingController(text: '0.1000');
  late final Ticker _frames;
  List<Map<String, dynamic>> _devices = [];
  String? _keyboard, _mouse, _shortcut, _identify, _speedError;
  bool _recording = false, _active = false, _ready = false, _busy = false;
  bool _readingPointer = false;
  int _frameGeneration = 0;
  double _speed = Sensitivity.defaultValue, _step = 0.0001;
  String _status = '';
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    _frames = createTicker((_) => _readPointer());
    _channel.setMethodCallHandler(_onNativeEvent);
    _initialize();
    _heartbeat = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_ready) {
        _channel.invokeMethod<void>('heartbeat').catchError((Object _) {});
      }
    });
  }

  // Pull the latest absolute native position once per display frame. One
  // outstanding call at most: a slow bridge never accumulates old mouse events.
  Future<void> _readPointer() async {
    if (!_active || _readingPointer) return;
    _readingPointer = true;
    final generation = _frameGeneration;
    try {
      final frame = await _channel.invokeListMethod<dynamic>('pointer');
      if (mounted &&
          _active &&
          generation == _frameGeneration &&
          frame != null &&
          frame.length >= 3 &&
          frame[2] == true) {
        _position.value = Offset(
          (frame[0] as num).toDouble(),
          (frame[1] as num).toDouble(),
        );
      }
    } on PlatformException {
      // Native watchdog remains responsible for releasing capture on failure.
    } on MissingPluginException {
      // An engine restart is handled by initialize, which always disarms capture.
    } finally {
      _readingPointer = false;
    }
  }

  Future<void> _initialize() async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      setState(() => _status = '输入采集目前仅支持 Windows。');
      return;
    }
    await _perform(() async {
      await _channel.invokeMethod<void>('initialize');
      await _refresh();
      if (mounted) setState(() => _ready = true);
    });
  }

  Future<void> _refresh() async {
    final values = await _channel.invokeListMethod<dynamic>('devices') ?? [];
    final devices = values
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      if (!devices.any((d) => d['id'] == _keyboard)) _keyboard = null;
      if (!devices.any((d) => d['id'] == _mouse)) _mouse = null;
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _status = error.message ?? error.code);
    } on MissingPluginException {
      if (mounted) setState(() => _status = '当前平台没有输入采集模块。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onNativeEvent(MethodCall call) async {
    if (!mounted) return;
    final data = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    switch (call.method) {
      case 'shortcut':
        setState(() {
          _shortcut = data['label'] as String;
          _recording = false;
          _status = '';
        });
      case 'recordingCancelled':
        setState(() {
          _recording = false;
          _status = '';
        });
      case 'identified':
        setState(() {
          if (data['type'] == 'keyboard') {
            _keyboard = data['id'] as String;
          } else {
            _mouse = data['id'] as String;
          }
          _identify = null;
          _status = '';
        });
      case 'identificationCancelled':
        setState(() {
          _identify = null;
          _status = '';
        });
      case 'devicesChanged':
        await _refresh();
      case 'stats':
        // Counters/countdown are independent of cursor rendering and settings.
        _stats.value = data;
      case 'stopped':
        ++_frameGeneration;
        _frames.stop();
        if (data['x'] is num && data['y'] is num) {
          _position.value = Offset(
            (data['x'] as num).toDouble(),
            (data['y'] as num).toDouble(),
          );
        }
        _stats.value = data;
        setState(() {
          _active = false;
          _status = _reason(data['reason'] as String? ?? 'manual');
        });
    }
  }

  String _reason(String value) => switch (value) {
    'shortcut' => '已通过快捷键退出。',
    'shake' => '已通过晃动鼠标退出。',
    'focus_lost' => '窗口失焦，已退出。',
    'timeout' => '已到 30 秒上限。',
    'heartbeat' => '界面响应中断，已释放鼠标。',
    'device_removed' => '所选设备已断开，已退出。',
    'window_changed' => '窗口位置或大小变化，已退出。',
    'shutdown' => '已退出。',
    _ => '已停止控制。',
  };

  Future<void> _record() => _perform(() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _channel.invokeMethod<void>('recordShortcut');
    if (mounted) {
      setState(() {
        _recording = true;
        _identify = null;
        _status = '按 Ctrl + Alt + 字母或 F6～F11，Esc 取消。';
      });
    }
  });

  Future<void> _identifyDevice(String type) => _perform(() async {
    await _channel.invokeMethod<void>('identify', {'type': type});
    if (mounted) {
      setState(() {
        _identify = type;
        _recording = false;
        _status = type == 'keyboard' ? '请按目标键盘。' : '请移动目标鼠标。';
      });
    }
  });

  Future<void> _start() => _perform(() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _channel.invokeMethod<void>('start', {
      'keyboard': _keyboard,
      'mouse': _mouse,
      'speed': _speed,
    });
    if (mounted) {
      _position.value = const Offset(300, 120);
      _stats.value = {};
      ++_frameGeneration;
      setState(() {
        _active = true;
        _status = '';
      });
      _frames.start();
    }
  });

  void _setSpeed(double value) {
    final gain = Sensitivity.quantize(value);
    setState(() {
      _speed = gain;
      _speedError = null;
      _speedText.text = gain.toStringAsFixed(4);
    });
  }

  @override
  void dispose() {
    ++_frameGeneration;
    _frames.dispose();
    _heartbeat?.cancel();
    _channel.setMethodCallHandler(null);
    _position.dispose();
    _stats.dispose();
    _speedText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canStart =
        _ready &&
        !_active &&
        !_recording &&
        _identify == null &&
        !_busy &&
        _keyboard != null &&
        _mouse != null &&
        _shortcut != null &&
        _speedError == null;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (constraints.maxWidth >= 850)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 300, child: _settings(canStart)),
                        const SizedBox(width: 28),
                        Expanded(child: _monitor()),
                      ],
                    )
                  else ...[
                    _settings(canStart),
                    const SizedBox(height: 28),
                    _monitor(),
                  ],
                  if (_status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        _status,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xffb6bec9),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _settings(bool canStart) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text('设备', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            onPressed: _ready && !_active && !_busy
                ? () => _perform(_refresh)
                : null,
            tooltip: '刷新设备',
            icon: const Icon(Icons.refresh, size: 19),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      const SizedBox(height: 10),
      _devicePicker('keyboard', '键盘', _keyboard),
      const SizedBox(height: 12),
      _devicePicker('mouse', '鼠标', _mouse),
      const SizedBox(height: 25),
      const Text('退出快捷键', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: _ready && !_active && !_busy ? _record : null,
          child: Text(_recording ? '等待组合键…' : _shortcut ?? '设置退出快捷键'),
        ),
      ),
      const SizedBox(height: 5),
      const Text(
        '也可快速晃动鼠标退出',
        style: TextStyle(fontSize: 12, color: Color(0xff929aa6)),
      ),
      const SizedBox(height: 25),
      const Text('灵敏度', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('sensitivity'),
              controller: _speedText,
              enabled: !_active,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                suffixText: '×',
                errorText: _speedError,
              ),
              onChanged: (text) => setState(() {
                final gain = Sensitivity.parse(text);
                _speedError = gain == null ? '范围 0.0001～4.0000' : null;
                if (gain != null) _speed = gain;
              }),
              onSubmitted: (_) {
                if (_speedError == null) _setSpeed(_speed);
              },
            ),
          ),
          IconButton(
            key: const Key('decrease-sensitivity'),
            tooltip: '降低灵敏度',
            onPressed: _active ? null : () => _setSpeed(_speed - _step),
            icon: const Icon(Icons.remove, size: 18),
          ),
          IconButton(
            key: const Key('increase-sensitivity'),
            tooltip: '提高灵敏度',
            onPressed: _active ? null : () => _setSpeed(_speed + _step),
            icon: const Icon(Icons.add, size: 18),
          ),
        ],
      ),
      Slider(
        value: Sensitivity.toSlider(_speed),
        onChanged: _active
            ? null
            : (value) => _setSpeed(Sensitivity.fromSlider(value)),
      ),
      Row(
        children: [
          const Expanded(
            child: Text(
              '0.0001× — 4×',
              style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
            ),
          ),
          PopupMenuButton<double>(
            enabled: !_active,
            initialValue: _step,
            tooltip: '调整加减步长',
            onSelected: (value) => setState(() => _step = value),
            itemBuilder: (_) => [0.0001, 0.001, 0.01, 0.1]
                .map(
                  (step) => PopupMenuItem(
                    value: step,
                    child: Text(step.toStringAsFixed(4)),
                  ),
                )
                .toList(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '步长 ${_step.toStringAsFixed(4)} ▾',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 26),
      SizedBox(
        width: double.infinity,
        height: 42,
        child: FilledButton(
          onPressed: canStart ? _start : null,
          child: Text(_active ? '控制中' : '开始控制'),
        ),
      ),
    ],
  );

  Widget _devicePicker(String type, String label, String? value) {
    final devices = _devices.where((d) => d['type'] == type).toList();
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('$type:$value:${devices.length}'),
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label),
            items: devices
                .map(
                  (d) => DropdownMenuItem<String>(
                    value: d['id'] as String,
                    child: Tooltip(
                      message: d['id'] as String,
                      child: Text(
                        '${d['usb'] == true ? 'USB · ' : ''}${d['name']}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                )
                .toList(),
            onChanged: _ready && !_active && !_busy
                ? (id) => setState(() {
                    if (type == 'keyboard') {
                      _keyboard = id;
                    } else {
                      _mouse = id;
                    }
                  })
                : null,
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          onPressed: _ready && !_active && !_busy
              ? () => _identifyDevice(type)
              : null,
          child: Text(_identify == type ? '等待…' : '识别'),
        ),
      ],
    );
  }

  Widget _monitor() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 36,
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '模拟桌面',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            ValueListenableBuilder<Map<String, dynamic>>(
              valueListenable: _stats,
              builder: (_, stats, _) => Text(
                _active
                    ? '控制中 · ${((stats['remainingMs'] as num? ?? 30000) / 1000).ceil()} s'
                    : '未开始',
                style: const TextStyle(fontSize: 12, color: Color(0xff929aa6)),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      AspectRatio(
        aspectRatio: 16 / 10,
        child: PointerPreview(position: _position),
      ),
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          title: const Text(
            '输入统计',
            style: TextStyle(fontSize: 12, color: Color(0xff929aa6)),
          ),
          children: [
            ValueListenableBuilder<Map<String, dynamic>>(
              valueListenable: _stats,
              builder: (_, stats, _) => Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 6,
                    children:
                        [
                              Text('键盘 ${stats['keys'] ?? 0}'),
                              Text('移动 ${stats['moves'] ?? 0}'),
                              Text('按钮 / 滚轮 ${stats['buttons'] ?? 0}'),
                              Text('已过滤 ${stats['ignored'] ?? 0}'),
                              Text('按住 ${stats['held'] ?? 0}'),
                            ]
                            .map(
                              (w) => DefaultTextStyle(
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xff929aa6),
                                ),
                                child: w,
                              ),
                            )
                            .toList(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
