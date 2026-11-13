import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'pointer_preview.dart';
import 'sensitivity.dart';
import 'settings.dart';
import 'remote/lan_session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SharedInputApp(store: PreferencesSettingsStore()));
}

class SharedInputApp extends StatelessWidget {
  const SharedInputApp({super.key, this.store});
  final SettingsStore? store;
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
    home: InputPage(store: store),
  );
}

class InputPage extends StatefulWidget {
  const InputPage({super.key, this.store});
  final SettingsStore? store;
  @override
  State<InputPage> createState() => _InputPageState();
}

class _InputPageState extends State<InputPage>
    with SingleTickerProviderStateMixin {
  static const _channel = MethodChannel('shared_input/dry_run');
  final _position = ValueNotifier(const Offset(300, 120));
  final _stats = ValueNotifier<Map<String, dynamic>>({});
  final _speedText = TextEditingController(text: '0.1000');
  final _hostText = TextEditingController();
  final _portText = TextEditingController(text: '45831');
  final _peerKeyText = TextEditingController();
  final _listenKeyText = TextEditingController();
  final _lan = LanSession();
  late final SettingsRepository _preferences;
  AppSettings _settings = AppSettings();
  bool _settingsLoaded = false;
  List<String> _addresses = [];
  bool get _captureSupported => defaultTargetPlatform == TargetPlatform.windows;
  bool get _receiving => _settings.role == InputRole.receiver;
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
    _preferences = SettingsRepository(widget.store ?? MemorySettingsStore());
    _lan.addListener(_connectionChanged);
    _lan.onBegin = (capture) =>
        _channel.invokeMethod<void>('receiverBegin', {'capture': capture});
    _lan.onInput = (capture, frames) => _channel.invokeMethod<void>(
      'receiverInput',
      {'capture': capture, 'frames': frames},
    );
    _lan.onHeartbeat = () => _channel.invokeMethod<void>('receiverHeartbeat');
    _lan.onEnd = () => _channel.invokeMethod<void>('receiverStop');
    _lan.onConnectionLost = () {
      if (mounted && _active) {
        unawaited(
          _channel.invokeMethod<void>('stop').catchError((Object _) {}),
        );
      }
    };
    _lan.onCaptureEnded = _lan.onConnectionLost;
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
    await _perform(() async {
      _settings = await _preferences.load();
      if (defaultTargetPlatform == TargetPlatform.macOS &&
          !_preferences.restored) {
        _settings.role = InputRole.receiver;
      }
      if (!mounted) return;
      setState(() {
        _settingsLoaded = true;
        _speed = _settings.sensitivity;
        _step = _settings.step;
        _speedText.text = _speed.toStringAsFixed(4);
        _hostText.text = _settings.host;
        _portText.text = '${_settings.port}';
        _peerKeyText.text = _settings.peerKey;
        _listenKeyText.text = _settings.listenKey;
        _shortcut = _settings.shortcut?.label;
      });
      if (defaultTargetPlatform != TargetPlatform.windows &&
          defaultTargetPlatform != TargetPlatform.macOS) {
        setState(() => _status = '输入共享目前支持 Windows 控制端和 Windows / macOS 被控端。');
        return;
      }
      await _channel.invokeMethod<void>('initialize');
      if (_captureSupported) {
        await _refresh();
        if (_settings.shortcut != null) {
          await _channel.invokeMethod<void>(
            'restoreShortcut',
            _settings.shortcut!.toJson(),
          );
        }
      }
      if (mounted) setState(() => _ready = true);
      await _saveSettings();
      unawaited(_readAddresses());
    });
  }

  Future<void> _readAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      if (mounted) {
        setState(
          () => _addresses = interfaces
              .expand((i) => i.addresses)
              .map((a) => a.address)
              .toList(),
        );
      }
    } on SocketException {
      /* IP entry is still usable without enumeration. */
    }
  }

  Future<void> _refresh() async {
    final values = await _channel.invokeListMethod<dynamic>('devices') ?? [];
    final devices = values
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _keyboard = devices.any((d) => d['id'] == _settings.keyboardId)
          ? _settings.keyboardId
          : null;
      _mouse = devices.any((d) => d['id'] == _settings.mouseId)
          ? _settings.mouseId
          : null;
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
    } catch (error) {
      if (mounted) setState(() => _status = '$error');
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
          _settings.shortcut = ExitShortcut.fromJson(data);
          _status = '';
        });
        await _saveSettings();
      case 'recordingCancelled':
        setState(() {
          _recording = false;
          _status = '';
        });
      case 'identified':
        setState(() {
          if (data['type'] == 'keyboard') {
            _keyboard = data['id'] as String;
            _settings.keyboardId = _keyboard;
          } else {
            _mouse = data['id'] as String;
            _settings.mouseId = _mouse;
          }
          _identify = null;
          _status = '';
        });
        await _saveSettings();
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
      case 'inputFrame':
        _lan.sendInput(data);
      case 'stopped':
        unawaited(_lan.endCapture());
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
    await _saveSettings();
    await _preferences.flush();
    if (_lan.connected) {
      await _lan.beginCapture();
    }
    try {
      await _channel.invokeMethod<void>('start', {
        'keyboard': _keyboard,
        'mouse': _mouse,
        'speed': _speed,
        'remote': _lan.capturing,
        'sendHz': _settings.sendHz,
      });
    } catch (_) {
      await _lan.endCapture();
      rethrow;
    }
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
    _persist();
  }

  Future<void> _saveSettings() async {
    if (!_settingsLoaded) return;
    _settings.sensitivity = _speed;
    _settings.step = _step;
    _settings.host = _hostText.text.trim();
    _settings.peerKey = _peerKeyText.text.trim();
    final port = int.tryParse(_portText.text);
    if (port != null && port > 0 && port <= 65535) _settings.port = port;
    await _preferences.save(_settings);
  }

  void _persist() {
    unawaited(
      _saveSettings().catchError((Object error) {
        if (mounted) setState(() => _status = '设置保存失败：$error');
      }),
    );
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _switchRole(int index) => _perform(() async {
    if (_active) await _channel.invokeMethod<void>('stop');
    await _lan.endCapture();
    await _lan.close();
    if (_ready) await _channel.invokeMethod<void>('cancelSetup');
    if (!mounted) return;
    setState(() {
      _settings.role = InputRole.values[index];
      _recording = false;
      _identify = null;
      _status = '';
    });
    await _saveSettings();
  });
  Future<void> _connect() => _perform(() async {
    final port = int.tryParse(_portText.text);
    if (port == null || port <= 0 || port > 65535) {
      throw const FormatException('端口范围为 1～65535。');
    }
    await _saveSettings();
    if (_receiving) {
      if (_lan.listening) {
        await _lan.close();
        return;
      }
      await _lan.listen(port: port, key: _settings.listenKey);
    } else {
      if (_lan.connected) {
        await _lan.close();
        return;
      }
      if (_hostText.text.trim().isEmpty) {
        throw const FormatException('请输入被控端 IP。');
      }
      await _lan.connect(
        host: _hostText.text,
        port: port,
        key: _peerKeyText.text,
      );
    }
    if (mounted) setState(() => _status = '');
  });

  @override
  void dispose() {
    ++_frameGeneration;
    _frames.dispose();
    _heartbeat?.cancel();
    _channel.setMethodCallHandler(null);
    _position.dispose();
    _stats.dispose();
    _speedText.dispose();
    _hostText.dispose();
    _portText.dispose();
    _peerKeyText.dispose();
    _listenKeyText.dispose();
    _lan.removeListener(_connectionChanged);
    _lan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canStart =
        _ready &&
        _captureSupported &&
        !_receiving &&
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
                  DefaultTabController(
                    key: ValueKey(_settings.role),
                    length: 2,
                    initialIndex: _settings.role.index,
                    child: IgnorePointer(
                      ignoring: _busy || _active,
                      child: TabBar(
                        onTap: (index) {
                          if (index != _settings.role.index) _switchRole(index);
                        },
                        tabs: const [
                          Tab(text: '控制端'),
                          Tab(text: '被控端'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_receiving)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: _receiverPanel(),
                    )
                  else if (constraints.maxWidth >= 850)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 300,
                          child: _controllerSettings(canStart),
                        ),
                        const SizedBox(width: 28),
                        Expanded(child: _monitor()),
                      ],
                    )
                  else ...[
                    _controllerSettings(canStart),
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

  Widget _controllerSettings(bool canStart) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (!_captureSupported)
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Text(
            '此设备支持被控端；键鼠采集目前在 Windows 上运行。',
            style: TextStyle(fontSize: 12),
          ),
        ),
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
                if (gain != null) _persist();
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
            onSelected: (value) {
              setState(() => _step = value);
              _persist();
            },
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
      Row(
        children: [
          const Expanded(child: Text('发送频率', style: TextStyle(fontSize: 12))),
          DropdownButton<int>(
            value: _settings.sendHz,
            items: [125, 250, 500, 1000]
                .map((hz) => DropdownMenuItem(value: hz, child: Text('$hz Hz')))
                .toList(),
            onChanged: _active
                ? null
                : (hz) {
                    if (hz != null) {
                      setState(() => _settings.sendHz = hz);
                      _persist();
                    }
                  },
          ),
        ],
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Text(
          'Win → Command · Ctrl → Control',
          style: TextStyle(fontSize: 12, color: Color(0xff929aa6)),
        ),
      ),
      SizedBox(
        width: double.infinity,
        height: 42,
        child: FilledButton(
          key: const Key('start-control'),
          onPressed: canStart ? _start : null,
          child: Text(
            _active
                ? '控制中'
                : _lan.connected
                ? '开始控制'
                : '开始本地预览',
          ),
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
                      _settings.keyboardId = id;
                    } else {
                      _mouse = id;
                      _settings.mouseId = id;
                    }
                    _persist();
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

  Widget _connectionPanel() {
    final editable =
        _ready && !_busy && !_active && !_lan.connected && !_lan.listening;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (!_receiving) ...[
              Expanded(
                child: TextField(
                  key: const Key('remote-host'),
                  controller: _hostText,
                  enabled: editable,
                  decoration: const InputDecoration(labelText: '被控端 IP'),
                  onChanged: (_) => _persist(),
                ),
              ),
              const SizedBox(width: 10),
            ] else
              const Expanded(
                child: Text(
                  '接收连接',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            SizedBox(
              width: 95,
              child: TextField(
                key: const Key('remote-port'),
                controller: _portText,
                enabled: editable,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '端口'),
                onChanged: (_) => _persist(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: Key(_receiving ? 'listen-key' : 'peer-key'),
                controller: _receiving ? _listenKeyText : _peerKeyText,
                enabled: _ready && !_active && !_busy,
                readOnly: _receiving || _lan.connected,
                decoration: InputDecoration(
                  labelText: '连接码',
                  suffixIcon: _receiving
                      ? IconButton(
                          tooltip: '复制连接码',
                          icon: const Icon(Icons.copy, size: 17),
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: _settings.listenKey),
                          ),
                        )
                      : null,
                ),
                onChanged: (_) => _persist(),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              key: const Key('connection-action'),
              onPressed: _ready && !_busy && !_active ? _connect : null,
              child: Text(
                _receiving
                    ? (_lan.listening ? '停止接收' : '开始接收')
                    : (_lan.connected ? '断开' : '连接'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          children: [
            Text(
              _lan.status,
              style: const TextStyle(fontSize: 12, color: Color(0xff929aa6)),
            ),
            ValueListenableBuilder<(int, int, double?)>(
              valueListenable: _lan.metrics,
              builder: (_, metrics, _) => !_lan.connected
                  ? const SizedBox.shrink()
                  : Text(
                      '${_receiving ? '接收 ${metrics.$2}' : '发送 ${metrics.$1}'} 包/s${metrics.$3 == null ? '' : ' · ${metrics.$3!.toStringAsFixed(1)} ms'}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff929aa6),
                      ),
                    ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _receiverPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('本机 IP', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      SelectableText(_addresses.isEmpty ? '正在读取…' : _addresses.join(' / ')),
      const SizedBox(height: 20),
      _connectionPanel(),
      const SizedBox(height: 16),
      Text(
        _lan.capturing ? '正在接收输入' : '在控制端填写本机 IP、端口和连接码后连接。',
        style: const TextStyle(fontSize: 12, color: Color(0xff929aa6)),
      ),
      if (defaultTargetPlatform == TargetPlatform.macOS)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton(
            onPressed: _busy
                ? null
                : () => _perform(() async {
                    final allowed =
                        await _channel.invokeMethod<bool>(
                          'requestPermissions',
                        ) ??
                        false;
                    if (mounted) {
                      setState(
                        () => _status = allowed
                            ? '已获得辅助功能权限。'
                            : '请在系统设置 → 隐私与安全性 → 辅助功能中允许 Shared Input。',
                      );
                    }
                  }),
            child: const Text('辅助功能授权'),
          ),
        ),
    ],
  );

  Widget _monitor() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _connectionPanel(),
      const SizedBox(height: 16),
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
                _active && !_lan.capturing
                    ? '控制中 · ${((stats['remainingMs'] as num? ?? 30000) / 1000).ceil()} s'
                    : _active
                    ? '控制中'
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
          key: ValueKey('statistics-$_settingsLoaded'),
          initiallyExpanded: _settings.statisticsExpanded,
          onExpansionChanged: (value) {
            _settings.statisticsExpanded = value;
            _persist();
          },
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
