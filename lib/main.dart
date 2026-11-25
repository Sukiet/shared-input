import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'control_return_log.dart';
import 'control_return_log_panel.dart';
import 'audio_output_panel.dart';
import 'audio_sync.dart';
import 'audio_sync_mode.dart';
import 'local_key.dart';
import 'local_key_panel.dart';
import 'edge_drag_preview.dart';
import 'drag_preview_link.dart';
import 'receiver_drag_hold.dart';
import 'private_text_field.dart';
import 'sensitivity.dart';
import 'scroll_speed.dart';
import 'display_layout.dart';
import 'display_layout_dialog.dart';
import 'clipboard_sync.dart';
import 'file_drag_sync.dart';
import 'screen_sync.dart';
import 'settings.dart';
import 'remote/lan_session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    SharedInputApp(
      store: PreferencesSettingsStore(),
      returnLogStore: PreferencesReturnLogStore(),
    ),
  );
}

class SharedInputApp extends StatelessWidget {
  const SharedInputApp({super.key, this.store, this.returnLogStore});
  final SettingsStore? store, returnLogStore;
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
    home: InputPage(store: store, returnLogStore: returnLogStore),
  );
}

class InputPage extends StatefulWidget {
  const InputPage({super.key, this.store, this.returnLogStore});
  final SettingsStore? store, returnLogStore;
  @override
  State<InputPage> createState() => _InputPageState();
}

class _ControlRun {
  _ControlRun(this.mode);
  final ControlMode mode;
  final elapsed = Stopwatch()..start();
  String? stopReason, stopDetail;
}

class _InputPageState extends State<InputPage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('shared_input/dry_run');
  final _stats = ValueNotifier<Map<String, dynamic>>({});
  final _audioOutput = ValueNotifier(const AudioOutputInfo());
  final _dragPreview = ValueNotifier(const EdgeDragPreview());
  bool _readingAudioOutput = false;
  final _speedText = TextEditingController(text: '0.1000');
  final _scrollSpeedText = TextEditingController(text: '3.00');
  final _hostText = TextEditingController();
  final _portText = TextEditingController(text: '45831');
  final _peerKeyText = TextEditingController();
  final _listenKeyText = TextEditingController();
  final _lan = LanSession();
  late final DragPreviewLink _dragLink;
  late final ReceiverDragHold _receiverDragHold;
  bool get _macReceiver => defaultTargetPlatform == TargetPlatform.macOS;
  bool get _dragSupported => _captureSupported || _macReceiver;
  late final ClipboardSync _clipboard;
  late final FileDragSync _fileDrag;
  late final ScreenSync _screenSync;
  late final AudioSync _audioSync;
  late final SettingsRepository _preferences;
  AppSettings _settings = AppSettings();
  bool _settingsLoaded = false;
  List<String> _addresses = [];
  bool get _captureSupported => defaultTargetPlatform == TargetPlatform.windows;
  bool get _receiving => _settings.role == InputRole.receiver;
  late final ControlReturnHistory _returnHistory;
  _ControlRun? _controlRun;
  List<Map<String, dynamic>> _devices = [];
  String? _keyboard, _mouse, _shortcut, _identify, _speedError;
  bool _recording = false, _active = false, _ready = false, _busy = false;
  bool _spaceArmed = false, _windowActive = true;
  bool _identifyingLocalKey = false;
  int _shortcutGeneration = 0;
  int _edgeGeneration = 0;
  int _attemptedDragFlow = 0;
  double _speed = Sensitivity.defaultValue, _step = 0.0001;
  String _status = '';
  Timer? _heartbeat;
  String? _scrollSpeedError;

  bool get _configuredForControl =>
      _ready &&
      _captureSupported &&
      !_receiving &&
      !_active &&
      !_recording &&
      _identify == null &&
      (_settings.edgeSwitchEnabled || (_keyboard != null && _mouse != null)) &&
      _shortcut != null &&
      _speedError == null &&
      _scrollSpeedError == null;

  bool get _canStart => _configuredForControl && !_busy;

  @override
  void initState() {
    super.initState();
    if (_macReceiver) {
      _dragPreview.value = const EdgeDragPreview(origin: DragOrigin.receiver);
    }
    _dragLink = DragPreviewLink(
      _lan,
      origin: _macReceiver ? DragOrigin.receiver : DragOrigin.controller,
      configureReceiver: (enabled, side) async {
        if (!_macReceiver || !_receiving) return;
        final data = await _channel.invokeMapMethod<String, dynamic>(
          'edgeDragProbe',
          {'enabled': enabled, 'side': side},
        );
        if (data != null) _setDragPreview(data);
      },
      clearLocal: _clearLocalDragPreview,
    );
    _dragLink.addListener(_syncReceiverDragTest);
    WidgetsBinding.instance.addObserver(this);
    // Override button activation for Space inside this app, before focus routing.
    FocusManager.instance.addEarlyKeyEventHandler(_onSpace);
    _preferences = SettingsRepository(widget.store ?? MemorySettingsStore());
    _returnHistory = ControlReturnHistory(
      widget.returnLogStore ?? MemorySettingsStore(),
    );
    _clipboard = ClipboardSync(_lan, _channel);
    _fileDrag = FileDragSync(_lan, _channel);
    _screenSync = ScreenSync(_lan, _channel);
    _audioSync = AudioSync(_lan, _channel);
    _receiverDragHold = ReceiverDragHold(_lan, _channel, supported: _captureSupported || _macReceiver);
    _lan.addListener(_connectionChanged);
    _lan.onBeginWithOptions = (capture, options) async {
      await _channel.invokeMethod<void>('receiverBegin', {'capture': capture, ...options});
      _receiverDragHold.nativeBegan();
    };
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      _lan.onPointerInfo = () =>
          _channel.invokeMapMethod<String, dynamic>('receiverPointer');
    }
    _lan.onPointerFeedback = (pointer) =>
        _channel.invokeMethod<void>('remotePointer', pointer);
    _lan.onInput = (capture, frames) => _channel.invokeMethod<void>(
      'receiverInput',
      {'capture': capture, 'frames': frames},
    );
    _lan.onHeartbeat = () => _channel.invokeMethod<void>('receiverHeartbeat');
    _lan.diagnostics.native = () =>
        _channel.invokeMapMethod<String, dynamic>('receiverDiagnostics');
    _lan.onEndWithReason = (reason) async {
      final generation = _lan.connectionGeneration;
      final state = await _channel.invokeMapMethod<String, dynamic>('receiverStop', {'reason': reason});
      await _receiverDragHold.nativeStopped(state, generation);
    };
    _lan.onConnectionLost = () {
      ++_edgeGeneration;
      if (mounted) {
        unawaited(
          _requestControlStop(
            'connection_lost',
            detail: _lan.status,
          ).catchError((Object _) {}),
        );
      }
    };
    _lan.onCaptureEnded = () {
      ++_edgeGeneration;
      if (mounted) {
        unawaited(_requestControlStop('remote_end').catchError((Object _) {}));
      }
    };
    _channel.setMethodCallHandler(_onNativeEvent);
    _initialize();
    _heartbeat = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_ready) {
        _channel.invokeMethod<void>('heartbeat').catchError((Object _) {});
      }
    });
  }

  Future<void> _requestControlStop(String reason, {String? detail}) async {
    final run = _controlRun;
    if (run == null) return;
    run.stopReason ??= reason;
    run.stopDetail ??= detail;
    await _channel.invokeMethod<void>('stop');
  }

  void _saveReturnLog(Future<void> write) {
    unawaited(
      write.catchError((Object error) {
        if (mounted) setState(() => _status = '断联日志保存失败：$error');
      }),
    );
  }

  Future<void> _initialize() async {
    await _perform(() async {
      try {
        await _returnHistory.load();
      } catch (_) {
        // Log storage must not disable the input recovery controls.
        if (mounted) setState(() => _status = '历史日志读取失败，将继续记录本次返回。');
      }
      if (!mounted) return;
      _settings = await _preferences.load();
      _dragLink.configureLayout(_settings.displayLayout);
      if (defaultTargetPlatform == TargetPlatform.macOS &&
          !_preferences.restored) {
        _settings.role = InputRole.receiver;
      }
      if (!mounted) return;
      _configureAudioSync();
      await _audioSync.initialize();
      if (!mounted) return;
      setState(() {
        _settingsLoaded = true;
        _speed = _settings.sensitivity;
        _step = _settings.step;
        _speedText.text = _speed.toStringAsFixed(4);
        _scrollSpeedText.text = _settings.scrollSpeed.toStringAsFixed(2);
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
      if (_captureSupported && !_receiving) unawaited(_readAudioOutput());
      await _channel.invokeMethod<void>('initialize', {
        'diagnostics': const bool.fromEnvironment('INPUT_DIAGNOSTICS'),
      });
      _screenSync.configure(_settings.screenPolicyEnabled, _settings.role);
      await _screenSync.initialize();
      await _fileDrag.initialize();
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await _applySmoothing();
        await _applyCursorSettings();
      }
      if (_captureSupported) {
        await _refresh();
        if (_settings.shortcut != null) {
          await _channel.invokeMethod<void>(
            'restoreShortcut',
            _settings.shortcut!.toJson(),
          );
        }
        await _configureLocalKeys(_settings.localKeys);
        await _syncDisplayLayout();
        await _configureEdge();
      }
      if (mounted) setState(() => _ready = true);
      _clipboard.start(_settings.clipboardEnabled);
      await _saveSettings();
      unawaited(_readAddresses());
    });
  }

  void _setAudioOutput(Map<String, dynamic> data) {
    if (!mounted) return;
    final info = AudioOutputInfo.fromMap(data);
    if (info.revision >= _audioOutput.value.revision) _audioOutput.value = info;
    _configureAudioSync();
  }

  void _configureAudioSync() => _audioSync.configure(
    _settings.audioSyncMode,
    _settings.role,
    _audioOutput.value,
    bufferMs: _settings.audioBufferMs,
  );

  void _syncReceiverDragTest() {
    if (!_ready || !_captureSupported) return;
    unawaited(
      _channel
          .invokeMethod<void>('receiverDragTest', {
            'enabled': _dragLink.receiverReady,
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> _readAudioOutput() async {
    if (!_captureSupported || _receiving || _readingAudioOutput) return;
    _readingAudioOutput = true;
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'audioOutput',
      );
      if (data != null) _setAudioOutput(data);
    } on PlatformException catch (error) {
      if (mounted) {
        _audioOutput.value = AudioOutputInfo(
          status: 'error',
          error: error.code,
          revision: _audioOutput.value.revision,
        );
        _configureAudioSync();
      }
    } on MissingPluginException {
      if (mounted) {
        _audioOutput.value = AudioOutputInfo(
          status: 'error',
          error: '请更新 Windows 程序',
          revision: _audioOutput.value.revision,
        );
        _configureAudioSync();
      }
    } finally {
      _readingAudioOutput = false;
    }
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
      if (mounted) {
        setState(() => _busy = false);
        _tryDragHandoff();
      }
    }
  }

  Future<void> _onNativeEvent(MethodCall call) async {
    if (!mounted) return;
    final data = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    switch (call.method) {
      case 'fileDragRequest':
      case 'fileDragCancel':
        _fileDrag.onNativeEvent(call.method, data);
      case 'screenStateChanged':
        _screenSync.onNativeState(data);
      case 'edgeDragProbeChanged':
        _setDragPreview(data);
        _tryDragHandoff();
      case 'localKeyIdentified':
        if (_identifyingLocalKey) {
          _identifyingLocalKey = false;
          Navigator.of(context).pop(LocalKeyException.fromJson(data));
        }
      case 'localKeyIdentificationCancelled':
        if (_identifyingLocalKey) {
          _identifyingLocalKey = false;
          Navigator.of(context).pop();
        }
      case 'audioOutputChanged':
        _setAudioOutput(data);
      case 'audioPlaybackState':
      case 'audioCaptureState':
        _audioSync.onNativeEvent(call.method, data);
      case 'edgeEnter':
        if (_settings.edgeSwitchEnabled && _canStart) {
          unawaited(_beginEdge(triggered: true));
        }
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
        // Only the statistics panel listens to these periodic updates.
        _stats.value = data;
      case 'inputFrame':
        _lan.sendInput(data);
      case 'receiverDragEnded':
        await _receiverDragHold.nativeEnded(data['token'] as String? ?? '');
      case 'stopped':
        final run = _controlRun;
        if (run == null) {
          return; // Duplicate/idle notifications are not returns.
        }
        _controlRun = null;
        final nativeReason = data['reason'] as String? ?? 'manual';
        final reason = nativeReason == 'manual'
            ? run.stopReason ?? nativeReason
            : nativeReason;
        final connected = _lan.connected;
        final ended = DateTime.now();
        _saveReturnLog(
          _returnHistory.add(
            ControlReturnEntry(
              time: ended,
              reason: reason,
              nativeReason: nativeReason,
              detail: reason == run.stopReason ? run.stopDetail : null,
              mode: run.mode,
              connected: connected,
              durationMs: run.elapsed.elapsedMilliseconds,
              exitDiagnostics: ControlReturnEntry.readDiagnostics(
                data['exitDiagnostics'],
              ),
            ),
          ),
        );
        ++_edgeGeneration;
        unawaited(_lan.endCapture(reason: reason));
        _stats.value = data;
        setState(() {
          _active = false;
          _status = _reason(reason);
        });
        _tryDragHandoff();
    }
  }

  String _reason(String value) => switch (value) {
    'edge' => '已切回 Windows。',
    'connection_lost' => '远程连接中断，已恢复 Windows 输入。',
    'remote_end' => '被控端结束控制，已恢复 Windows 输入。',
    'manual_disconnect' => '已断开连接，已恢复 Windows 输入。',
    'role_changed' => '已结束控制并切换角色。',
    'input_overflow' => '待发送输入队列溢出，已恢复 Windows 输入。',
    'pointer_timeout' => 'Mac 指针反馈中断，已恢复 Windows 输入。',
    'hook_lost' => '后台输入拦截中断，已恢复 Windows 输入。',
    'shortcut' => '已通过快捷键退出。',
    'focus_lost' => '窗口失焦，已退出。',
    'timeout' => '已到 30 秒上限。',
    'heartbeat' => '界面响应中断，已释放鼠标。',
    'device_removed' => '所选设备已断开，已退出。',
    'window_changed' => '窗口位置或大小变化，已退出。',
    'system_lock' => '系统锁屏或会话切换，已释放输入。',
    'system_suspend' => '系统进入休眠，已释放输入。',
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

  void _setDragPreview(Map<String, dynamic> data) {
    if (!mounted) return;
    final value = EdgeDragPreview.fromMap({
      ...data,
      'origin': _macReceiver ? 'receiver' : 'controller',
    });
    if (value.revision < _dragPreview.value.revision) return;
    final changed = value.enabled != _dragPreview.value.enabled;
    _dragPreview.value = value;
    _dragLink.publish(value);
    if (value.dragFlow == 0) _attemptedDragFlow = 0;
    if (changed) setState(() {});
  }

  Future<void> _toggleDragPreview(bool enabled) => _perform(() async {
    final data = await _channel.invokeMapMethod<String, dynamic>(
      'edgeDragProbe',
      {'enabled': enabled},
    );
    if (data != null) _setDragPreview(data);
  });
  Future<void> _clearDragPreview() => _perform(_dragLink.clearBoth);
  Future<void> _clearLocalDragPreview() async {
    final data = await _channel.invokeMapMethod<String, dynamic>(
      'edgeDragProbeClear',
    );
    if (data != null) _setDragPreview(data);
  }

  Future<void> _configureLocalKeys(List<LocalKeyException> keys) =>
      _channel.invokeMethod<void>('configureLocalKeys', {
        'keys': keys.map((key) => key.key).toList(),
      });

  Future<void> _addLocalKey() => _perform(() async {
    FocusManager.instance.primaryFocus?.unfocus();
    _identifyingLocalKey = true;
    final dialog = showDialog<LocalKeyException>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('识别例外按键'),
        content: const Text('请按一个键，或向一个方向转动音量旋钮。\n10 秒内未识别会自动取消。'),
        actions: [
          TextButton(
            key: const Key('cancel-local-key'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    try {
      await _channel.invokeMethod<void>('identifyLocalKey');
      final key = await dialog;
      _identifyingLocalKey = false;
      if (!mounted || key == null) return;
      if (_settings.localKeys.any((item) => item.key == key.key)) {
        setState(() => _status = '这个按键已在例外列表中。');
        return;
      }
      final keys = [..._settings.localKeys, key];
      await _configureLocalKeys(keys);
      if (!mounted) return;
      setState(() {
        _settings.localKeys = keys;
        _status = '${key.label} 已留在 Windows。';
      });
      await _saveSettings();
    } catch (_) {
      if (mounted && _identifyingLocalKey) {
        _identifyingLocalKey = false;
        Navigator.of(context).pop();
      }
      rethrow;
    } finally {
      _identifyingLocalKey = false;
      await _channel.invokeMethod<void>('cancelSetup');
    }
  });

  Future<void> _removeLocalKey(LocalKeyException key) => _perform(() async {
    final keys = _settings.localKeys
        .where((item) => item.key != key.key)
        .toList();
    await _configureLocalKeys(keys);
    if (!mounted) return;
    setState(() => _settings.localKeys = keys);
    await _saveSettings();
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _windowActive = state == AppLifecycleState.resumed;
    if (_windowActive && _ready && !_receiving) unawaited(_readAudioOutput());
    if (!_windowActive) {
      _spaceArmed = false;
      ++_shortcutGeneration;
    }
  }

  KeyEventResult _onSpace(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      _spaceArmed = false;
      return KeyEventResult.ignored;
    }
    final editing =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;
    if (event is KeyUpEvent) {
      // Native capture rejects held keys, so start only after releasing Space.
      final armed = _spaceArmed;
      _spaceArmed = false;
      if (!armed) return KeyEventResult.ignored;
      if (!event.synthesized &&
          _canStart &&
          _windowActive &&
          !editing &&
          HardwareKeyboard.instance.logicalKeysPressed.isEmpty) {
        unawaited(_connectAndStart());
      }
      return KeyEventResult.handled;
    }
    if (_spaceArmed) return KeyEventResult.handled;
    if (event is KeyDownEvent &&
        !event.synthesized &&
        _canStart &&
        _windowActive &&
        !editing &&
        HardwareKeyboard.instance.logicalKeysPressed.length == 1) {
      _spaceArmed = true;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _connectAndStart() async {
    if (_settings.edgeSwitchEnabled) {
      await _beginEdge();
      return;
    }
    if (!_canStart) return;
    final generation = _shortcutGeneration;
    bool allowed() =>
        mounted &&
        _windowActive &&
        generation == _shortcutGeneration &&
        _configuredForControl &&
        _lan.connected;
    await _perform(() async {
      if (!_lan.connected) await _changeConnection();
      if (allowed()) await _startCapture(allowed: allowed);
    });
  }

  Future<void> _configureEdge() async {
    if (_captureSupported) {
      await _channel.invokeMethod<void>('configureEdge', {
        'enabled': !_receiving && _settings.edgeSwitchEnabled,
        'layout': _settings.displayLayout.nativeOptions,
      });
    }
  }

  Future<void> _setEdge(bool enabled) => _perform(() async {
    ++_edgeGeneration;
    await _channel.invokeMethod<void>('configureEdge', {
      'enabled': enabled,
      'layout': _settings.displayLayout.nativeOptions,
    });
    if (!mounted) return;
    setState(() => _settings.edgeSwitchEnabled = enabled);
    await _saveSettings();
  });

  Future<void> _syncDisplayLayout() async {
    if (!_captureSupported) return;
    double? aspect(Map<String, dynamic>? info) {
      final width = info?['width'], height = info?['height'];
      if (width is! num ||
          height is! num ||
          !width.isFinite ||
          !height.isFinite ||
          width <= 1 ||
          height <= 1) {
        return null;
      }
      final ratio = width / height;
      return ratio >= 0.2 && ratio <= 5 ? ratio : null;
    }

    final local = await _channel.invokeMapMethod<String, dynamic>(
      'displayInfo',
    );
    if (!mounted) return;
    final layout = _settings.displayLayout.copyWith(
      controllerAspect: aspect(local),
      remoteAspect: aspect(_lan.remoteDisplay),
    );
    await _channel.invokeMethod<void>('configureLayout', layout.nativeOptions);
    if (!mounted) return;
    setState(() => _settings.displayLayout = layout);
    _dragLink.configureLayout(layout);
    await _saveSettings();
  }

  Future<void> _editDisplayLayout() => _perform(() async {
    final result = await showDialog<DisplayLayout>(
      context: context,
      builder: (_) => DisplayLayoutDialog(layout: _settings.displayLayout),
    );
    if (result == null || !mounted) return;
    await _channel.invokeMethod<void>('configureLayout', result.nativeOptions);
    if (!mounted) return;
    ++_edgeGeneration;
    setState(() => _settings.displayLayout = result);
    _dragLink.configureLayout(result);
    await _saveSettings();
  });

  Future<void> _beginEdge({bool triggered = false}) async {
    if (!_canStart || !_settings.edgeSwitchEnabled) return;
    final generation = _edgeGeneration;
    bool allowed() =>
        mounted &&
        generation == _edgeGeneration &&
        _settings.edgeSwitchEnabled &&
        _configuredForControl &&
        _lan.connected;
    await _perform(() async {
      if (!_lan.connected) await _changeConnection();
      if (!allowed()) return;
      if (!_lan.supportsEdge) throw StateError('请更新 Mac 被控端以支持边缘切换。');
      final state =
          await _channel.invokeMapMethod<String, dynamic>('edgeState') ?? {};
      if (state['ready'] != true) {
        throw PlatformException(
          code: state['held'] == true ? 'keys_held' : 'hook_recovery_failed',
          message: state['held'] == true
              ? '检测到键盘按键或鼠标按钮仍按住，请松开后重试。'
              : '后台输入拦截正在恢复，请稍后重试。',
        );
      }
      if (!allowed() || (triggered && state['atEdge'] != true)) return;
      await _startCapture(
        allowed: allowed,
        background: true,
        edgeTriggered: triggered,
        entryY: (state['entryY'] as num? ?? 0.5).toDouble(),
        entrySide: state['entrySide'] as String? ?? 'left',
      );
    });
  }

  bool get _canDragHandoff =>
      _ready &&
      _captureSupported &&
      !_receiving &&
      !_active &&
      !_busy &&
      !_recording &&
      !_identifyingLocalKey &&
      _identify == null &&
      _settings.edgeSwitchEnabled &&
      _shortcut != null &&
      _speedError == null &&
      _scrollSpeedError == null &&
      _dragPreview.value.enabled &&
      _dragPreview.value.gestureActive;

  void _tryDragHandoff() {
    final drag = _dragPreview.value;
    if (_canDragHandoff &&
        drag.dragStage == 'edge' &&
        drag.dragFlow != _attemptedDragFlow) {
      unawaited(_beginDragHandoff(drag.dragFlow));
    }
  }

  Future<void> _beginDragHandoff(int flow) async {
    if (!_canDragHandoff || flow == 0 || flow == _attemptedDragFlow) return;
    _attemptedDragFlow = flow;
    final generation = _edgeGeneration;
    bool allowed() {
      final drag = _dragPreview.value;
      return mounted &&
          generation == _edgeGeneration &&
          !_receiving &&
          !_active &&
          _ready &&
          _settings.edgeSwitchEnabled &&
          _shortcut != null &&
          drag.enabled &&
          drag.gestureActive &&
          drag.dragFlow == flow &&
          (drag.dragStage == 'edge' || drag.dragStage == 'switching');
    }

    await _perform(() async {
      var completed = false;
      String message = '拖拽已结束或已离开边缘，已取消跨屏。';
      try {
        await _channel.invokeMethod<void>('prepareDragHandoff', {'flow': flow});
        if (!allowed()) return;
        if (!_lan.connected) await _changeConnection();
        if (!allowed() || !_lan.connected) return;
        if (!_lan.supportsEdge) throw StateError('请更新 Mac 被控端以支持边缘切换。');
        final state =
            await _channel.invokeMapMethod<String, dynamic>('edgeState') ?? {};
        if (!allowed() || state['atEdge'] != true) return;
        await _startCapture(
          allowed: allowed,
          background: true,
          edgeTriggered: true,
          dragFlow: flow,
          entryY: (state['entryY'] as num? ?? 0.5).toDouble(),
          entrySide: state['entrySide'] as String? ?? 'left',
        );
        completed = _active;
      } catch (error) {
        message = error is PlatformException
            ? error.message ?? error.code
            : '$error';
        rethrow;
      } finally {
        if (!completed && mounted) {
          await _channel.invokeMethod<void>('abortDragHandoff', {
            'flow': flow,
            'message': message,
          });
        }
      }
    });
  }

  Future<void> _start() =>
      _settings.edgeSwitchEnabled ? _beginEdge() : _perform(_startCapture);

  Future<void> _startCapture({
    bool Function()? allowed,
    bool background = false,
    bool edgeTriggered = false,
    double entryY = 0.5,
    String entrySide = 'left',
    int? dragFlow,
  }) async {
    if (!background) FocusManager.instance.primaryFocus?.unfocus();
    await _saveSettings();
    await _preferences.flush();
    if (allowed != null && !allowed()) return;
    Map<String, dynamic>? resume;
    Map<String, dynamic>? fileDrag;
    if (dragFlow != null) {
      fileDrag = await _fileDrag.prepare(_dragPreview.value, current: () => _dragPreview.value);
      if (allowed != null && !allowed()) return;
    }
    if (_lan.connected) {
      resume = await _receiverDragHold.beginCapture(
        edgeEntryY: background ? entryY : null,
        edgeEntrySide: entrySide,
        allowResume: background && dragFlow != null,
        allowed: allowed,
        fileDrag: fileDrag,
      );
    }
    if (allowed != null && !allowed()) {
      await _lan.endCapture(reason: resume != null ? 'resume_cancelled' : null);
      return;
    }
    final run = _ControlRun(
      background
          ? ControlMode.background
          : _lan.capturing
          ? ControlMode.remote
          : ControlMode.local,
    );
    _controlRun = run;
    try {
      await _channel.invokeMethod<void>('start', {
        'keyboard': _keyboard,
        'mouse': _mouse,
        'speed': _speed,
        'remote': _lan.capturing,
        'sendHz': _settings.sendHz,
        'background': background,
        'edgeTriggered': edgeTriggered,
        'dragFlow': ?dragFlow,
        'fileDrag': fileDrag != null,
        'receiverDragResume': ?resume,
      });
      if (mounted && identical(_controlRun, run)) {
        unawaited(_receiverDragHold.confirmResume(resume));
      }
    } catch (_) {
      if (identical(_controlRun, run)) _controlRun = null;
      await _lan.endCapture(reason: resume != null ? 'resume_cancelled' : null);
      rethrow;
    }
    // A native emergency exit may arrive before the start reply.
    if (mounted && identical(_controlRun, run)) {
      _stats.value = {};
      setState(() {
        _active = true;
        _status = '';
      });
    }
  }

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
    _lan.scrollSpeed = _settings.scrollSpeed;
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
    ++_edgeGeneration;
    if (_dragSupported && _dragPreview.value.enabled) {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'edgeDragProbe',
        {'enabled': false},
      );
      if (data != null) _setDragPreview(data);
    }
    if (_controlRun != null) await _requestControlStop('role_changed');
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
    await _configureEdge();
    _configureAudioSync();
    if (!_receiving) unawaited(_readAudioOutput());
    _screenSync.configure(_settings.screenPolicyEnabled, _settings.role);
  });
  Future<void> _connect() => _perform(_changeConnection);

  Future<void> _changeConnection() async {
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
        await _requestControlStop('manual_disconnect');
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
      await _syncDisplayLayout();
    }
    if (mounted) setState(() => _status = '');
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onSpace);
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    _channel.setMethodCallHandler(null);
    _stats.dispose();
    _audioOutput.dispose();
    if (_dragSupported) {
      unawaited(
        _channel
            .invokeMethod<Object?>('edgeDragProbe', {'enabled': false})
            .then<void>((_) {})
            .catchError((Object _) {}),
      );
    }
    _dragPreview.dispose();
    _receiverDragHold.dispose();
    _dragLink.dispose();
    _returnHistory.dispose();
    _speedText.dispose();
    _scrollSpeedText.dispose();
    _hostText.dispose();
    _portText.dispose();
    _peerKeyText.dispose();
    _listenKeyText.dispose();
    _lan.removeListener(_connectionChanged);
    _audioSync.dispose();
    _screenSync.dispose();
    _clipboard.dispose();
    _fileDrag.dispose();
    _lan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canStart = _canStart;
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
      if (_captureSupported)
        SwitchListTile(
          key: const Key('edge-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('屏幕边缘切换'),
          subtitle: Text(
            'Win 主屏${_settings.displayLayout.side.label} ↔ Mac 主屏${_settings.displayLayout.side.opposite.label}\n全部键鼠一起切换，可在后台运行',
            style: const TextStyle(fontSize: 11),
          ),
          value: _settings.edgeSwitchEnabled,
          onChanged: _ready && !_busy && !_active ? _setEdge : null,
        ),
      if (_captureSupported)
        TextButton.icon(
          key: const Key('display-layout-settings'),
          onPressed: _ready && !_busy && !_active ? _editDisplayLayout : null,
          icon: const Icon(Icons.settings_outlined, size: 17),
          label: const Text('显示屏设置'),
        ),
      if (!_captureSupported)
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Text(
            '此设备支持被控端；键鼠采集目前在 Windows 上运行。',
            style: TextStyle(fontSize: 12),
          ),
        ),
      if (!_settings.edgeSwitchEnabled) ...[
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
      ],
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
      const SizedBox(height: 20),
      Row(
        children: [
          const Expanded(
            child: Text('滚轮速度', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          SizedBox(
            width: 100,
            child: TextField(
              key: const Key('scroll-speed'),
              controller: _scrollSpeedText,
              enabled: _ready && !_busy && !_active,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                suffixText: '×',
                errorText: _scrollSpeedError,
              ),
              onChanged: (text) {
                final value = ScrollSpeed.parse(text);
                setState(() {
                  _scrollSpeedError = value == null ? '0.01～20' : null;
                  if (value != null) _settings.scrollSpeed = value;
                });
                if (value != null) _persist();
              },
              onSubmitted: (_) {
                if (_scrollSpeedError == null) {
                  _scrollSpeedText.text = _settings.scrollSpeed.toStringAsFixed(
                    2,
                  );
                }
              },
            ),
          ),
        ],
      ),
      Slider(
        key: const Key('scroll-speed-slider'),
        value: ScrollSpeed.toSlider(_settings.scrollSpeed),
        label: '${_settings.scrollSpeed.toStringAsFixed(2)}×',
        onChanged: _ready && !_busy && !_active
            ? (position) {
                setState(() {
                  _settings.scrollSpeed = ScrollSpeed.fromSlider(position);
                  _scrollSpeedText.text = _settings.scrollSpeed.toStringAsFixed(
                    2,
                  );
                  _scrollSpeedError = null;
                });
                _persist();
              }
            : null,
      ),
      const Text(
        'Mac · 0.01× — 20×',
        style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
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
      if (!_active)
        const Padding(
          padding: EdgeInsets.only(top: 7),
          child: Text(
            'Space 连接并开始控制',
            style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
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
                child: PrivateTextField(
                  fieldKey: const Key('remote-host'),
                  controller: _hostText,
                  enabled: editable,
                  label: '被控端 IP',
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
              child: PrivateTextField(
                key: ValueKey(_receiving),
                fieldKey: Key(_receiving ? 'listen-key' : 'peer-key'),
                controller: _receiving ? _listenKeyText : _peerKeyText,
                enabled: _ready && !_active && !_busy,
                readOnly: _receiving || _lan.connected,
                label: '连接码',
                onCopy: _receiving
                    ? () => Clipboard.setData(
                        ClipboardData(text: _settings.listenKey),
                      )
                    : null,
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
        _clipboardSettings(),
        if (!_receiving && _captureSupported) _screenPolicySettings(),
      ],
    );
  }

  Widget _clipboardSettings() => ListenableBuilder(
    listenable: _clipboard,
    builder: (_, _) => SwitchListTile(
      key: const Key('clipboard-sync'),
      contentPadding: EdgeInsets.zero,
      title: const Text('剪贴板同步'),
      subtitle: Text(_clipboard.status, style: const TextStyle(fontSize: 11)),
      value: _settings.clipboardEnabled,
      onChanged: _ready && !_busy
          ? (value) {
              setState(() => _settings.clipboardEnabled = value);
              _clipboard.setEnabled(value);
              _persist();
            }
          : null,
    ),
  );

  Widget _screenPolicySettings() => ListenableBuilder(
    listenable: _screenSync,
    builder: (_, _) => SwitchListTile(
      key: const Key('screen-policy-sync'),
      contentPadding: EdgeInsets.zero,
      title: const Text('屏幕与锁屏同步'),
      subtitle: Text(_screenSync.status, style: const TextStyle(fontSize: 11)),
      value: _settings.screenPolicyEnabled,
      onChanged: _ready && !_busy ? (value) {
        setState(() => _settings.screenPolicyEnabled = value);
        _screenSync.configure(value, _settings.role);
        _persist();
      } : null,
    ),
  );

  Future<void> _applySmoothing() => _channel.invokeMethod<void>(
    'receiverConfigureSmoothing',
    _settings.smoothingOptions,
  );

  Future<void> _applyCursorSettings() => _channel.invokeMethod<void>(
    'receiverConfigureCursor',
    {'parkOnExit': _settings.parkCursorOnExit},
  );

  Widget _cursorSettings() => SwitchListTile(
    key: const Key('park-cursor-on-exit'),
    contentPadding: EdgeInsets.zero,
    title: const Text('控制结束后移至左上角'),
    subtitle: const Text('将鼠标指针移至当前屏幕左上角。', style: TextStyle(fontSize: 11)),
    value: _settings.parkCursorOnExit,
    onChanged: _ready && !_busy
        ? (value) {
            setState(() => _settings.parkCursorOnExit = value);
            _persist();
            unawaited(
              _applyCursorSettings().catchError((Object error) {
                if (mounted) setState(() => _status = '鼠标设置应用失败：$error');
              }),
            );
          }
        : null,
  );

  void _updateSmoothing(VoidCallback change) {
    setState(change);
    _persist();
    unawaited(
      _applySmoothing().catchError((Object error) {
        if (mounted) setState(() => _status = '平滑设置应用失败：$error');
      }),
    );
  }

  Widget _smoothingSlider({
    required String label,
    required String valueLabel,
    required String hint,
    required String id,
    required int value,
    required int min,
    required int max,
    int step = 1,
    bool? active,
    required ValueChanged<int> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(valueLabel),
        ],
      ),
      Slider(
        key: Key(id),
        value: value.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: (max - min) ~/ step,
        label: valueLabel,
        onChanged:
            _ready &&
                (active ?? (_settings.effectivePointerMode == 'interpolation'))
            ? (v) => onChanged((v / step).round() * step)
            : null,
      ),
      Text(
        hint,
        style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
      ),
      const SizedBox(height: 14),
    ],
  );

  Widget _smoothingSettings() => Container(
    key: const Key('receiver-smoothing-settings'),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xff191c21),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xff343b45)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '鼠标平滑设置',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              key: const Key('reset-smoothing'),
              onPressed: !_ready
                  ? null
                  : () => _updateSmoothing(() {
                      _settings.smoothingEnabled = true;
                      _settings.pointerMode = 'interpolation';
                      _settings.predictionTriggerMs = 8;
                      _settings.predictionHorizonMs = 60;
                      _settings.predictionDecayMs = 40;
                      _settings.predictionHistoryMs = 20;
                      _settings.predictionMaxDistance = 32;
                      _settings.predictionOutputSmoothing = true;
                      _settings.predictionOutputDurationMs = 8;
                      _settings.smoothingDurationMs = 12;
                      _settings.smoothingIntervalMs = 4;
                      _settings.smoothingLeewayUs = 500;
                    }),
              child: const Text('恢复默认'),
            ),
          ],
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('pointer-mode-${_settings.effectivePointerMode}'),
          initialValue: _settings.effectivePointerMode,
          decoration: const InputDecoration(labelText: '鼠标处理模式'),
          items: const [
            DropdownMenuItem(value: 'direct', child: Text('直接跟随')),
            DropdownMenuItem(value: 'interpolation', child: Text('平滑插值')),
            DropdownMenuItem(value: 'prediction', child: Text('预测补偿')),
          ],
          onChanged: !_ready
              ? null
              : (mode) => _updateSmoothing(() {
                  _settings.pointerMode = mode!;
                  _settings.smoothingEnabled = mode == 'interpolation';
                }),
        ),
        const SizedBox(height: 12),
        if (_settings.effectivePointerMode != 'prediction')
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              key: const Key('smoothing-enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('启用平滑插值'),
              subtitle: const Text(
                '调整立即生效，自动保存；关闭后直接跟随收到的位移。',
                style: TextStyle(fontSize: 11),
              ),
              value: _settings.smoothingEnabled,
              onChanged: !_ready
                  ? null
                  : (value) => _updateSmoothing(
                      () => _settings.smoothingEnabled = value,
                    ),
            ),
          ),
        const SizedBox(height: 12),
        if (_settings.effectivePointerMode != 'prediction')
          _smoothingSlider(
            label: '平滑时长',
            valueLabel: '${_settings.smoothingDurationMs} ms',
            hint: '1–100 ms；越大越平滑，跟手延迟也越大。默认 12 ms。',
            id: 'smoothing-duration',
            value: _settings.smoothingDurationMs,
            min: 1,
            max: 100,
            onChanged: (v) =>
                _updateSmoothing(() => _settings.smoothingDurationMs = v),
          ),
        _smoothingSlider(
          label: '更新间隔',
          active: _settings.effectivePointerMode != 'direct',
          valueLabel: '${_settings.smoothingIntervalMs} ms',
          hint: '1–16 ms；越小更新越频繁、开销越高。默认 4 ms。',
          id: 'smoothing-interval',
          value: _settings.smoothingIntervalMs,
          min: 1,
          max: 16,
          onChanged: (v) =>
              _updateSmoothing(() => _settings.smoothingIntervalMs = v),
        ),
        _smoothingSlider(
          label: '调度容差',
          active: _settings.effectivePointerMode != 'direct',
          valueLabel:
              '${(_settings.smoothingLeewayUs / 1000).toStringAsFixed(1)} ms',
          hint: '0–2 ms；允许系统合并定时唤醒的余量，越小越严格。默认 0.5 ms。',
          id: 'smoothing-leeway',
          value: _settings.smoothingLeewayUs,
          min: 0,
          max: 2000,
          step: 100,
          onChanged: (v) =>
              _updateSmoothing(() => _settings.smoothingLeewayUs = v),
        ),
        if (_settings.effectivePointerMode == 'prediction') ...[
          Text(
            _lan.connected && !_lan.supportsPrediction
                ? '对端不支持预测时间戳，请更新 Windows 控制端；当前仅直接跟随。'
                : '预测可叠加输出平滑，减轻跳变但增加跟随延迟；拖拽时直接跟随。',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              key: const Key('prediction-output-smoothing'),
              contentPadding: EdgeInsets.zero,
              title: const Text('预测输出平滑'),
              subtitle: const Text(
                '平滑预测点和真实数据纠偏，关闭后保留原来的直接输出。',
                style: TextStyle(fontSize: 11),
              ),
              value: _settings.predictionOutputSmoothing,
              onChanged: !_ready
                  ? null
                  : (v) => _updateSmoothing(
                      () => _settings.predictionOutputSmoothing = v,
                    ),
            ),
          ),
          _smoothingSlider(
            label: '预测平滑时长',
            valueLabel: '${_settings.predictionOutputDurationMs} ms',
            hint: '1–40 ms；默认 8 ms。越大越柔和，跟手延迟也越大。',
            id: 'prediction-output-duration',
            value: _settings.predictionOutputDurationMs,
            min: 1,
            max: 40,
            active: _settings.predictionOutputSmoothing,
            onChanged: (v) => _updateSmoothing(
              () => _settings.predictionOutputDurationMs = v,
            ),
          ),
          _smoothingSlider(
            label: '空窗触发阈值',
            valueLabel: '${_settings.predictionTriggerMs} ms',
            hint: '默认 8 ms；超过此空窗后才开始预测。',
            id: 'prediction-trigger',
            value: _settings.predictionTriggerMs,
            min: 1,
            max: 50,
            active: true,
            onChanged: (v) =>
                _updateSmoothing(() => _settings.predictionTriggerMs = v),
          ),
          _smoothingSlider(
            label: '最大预测时长',
            valueLabel: '${_settings.predictionHorizonMs} ms',
            hint: '默认 60 ms；达到上限后保持当前位置。',
            id: 'prediction-horizon',
            value: _settings.predictionHorizonMs,
            min: 1,
            max: 100,
            active: true,
            onChanged: (v) =>
                _updateSmoothing(() => _settings.predictionHorizonMs = v),
          ),
          _smoothingSlider(
            label: '速度衰减时间',
            valueLabel: '${_settings.predictionDecayMs} ms',
            hint: '默认 40 ms；越大保持动量越久。',
            id: 'prediction-decay',
            value: _settings.predictionDecayMs,
            min: 1,
            max: 200,
            active: true,
            onChanged: (v) =>
                _updateSmoothing(() => _settings.predictionDecayMs = v),
          ),
          _smoothingSlider(
            label: '估速历史窗口',
            valueLabel: '${_settings.predictionHistoryMs} ms',
            hint: '默认 20 ms；按发送端时间估算近期速度。',
            id: 'prediction-history',
            value: _settings.predictionHistoryMs,
            min: 4,
            max: 100,
            active: true,
            onChanged: (v) =>
                _updateSmoothing(() => _settings.predictionHistoryMs = v),
          ),
          _smoothingSlider(
            label: '最大预测距离',
            valueLabel: '${_settings.predictionMaxDistance} ',
            hint: '默认 32 个光标坐标单位；限制过冲距离。',
            id: 'prediction-distance',
            value: _settings.predictionMaxDistance,
            min: 1,
            max: 200,
            active: true,
            onChanged: (v) =>
                _updateSmoothing(() => _settings.predictionMaxDistance = v),
          ),
        ],
        const Text(
          '点击和拖拽状态切换前会立即到达目标；停止控制时取消剩余插值。',
          style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
        ),
      ],
    ),
  );

  Widget _receiverPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (defaultTargetPlatform == TargetPlatform.macOS) ...[
        _cursorSettings(),
        const SizedBox(height: 12),
        _smoothingSettings(),
        const SizedBox(height: 20),
      ],
      const Text('本机 IP', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      SelectableText(_addresses.isEmpty ? '正在读取…' : _addresses.join(' / ')),
      const SizedBox(height: 20),
      _connectionPanel(),
      if (defaultTargetPlatform == TargetPlatform.macOS) ...[
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: _audioSync,
          builder: (_, _) => Text(
            _audioSync.status,
            style: const TextStyle(fontSize: 12, color: Color(0xff929aa6)),
          ),
        ),
      ],
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
      if (_macReceiver) ...[const SizedBox(height: 18), _dragPanel()],
    ],
  );

  Widget _dragPanel() => ListenableBuilder(
    listenable: Listenable.merge([_dragLink, _fileDrag]),
    builder: (_, _) => ValueListenableBuilder<EdgeDragPreview>(
      valueListenable: _dragPreview,
      builder: (_, preview, _) {
        final side = ScreenSide.values.firstWhere(
          (side) => side.name == preview.side,
          orElse: () => _macReceiver
              ? _settings.displayLayout.side.opposite
              : _settings.displayLayout.side,
        );
        return EdgeDragPreviewPanel(
          preview: preview,
          peer: _dragLink.peer,
          syncStatus: '${_dragLink.status}\n${_fileDrag.status}',
          edgeLabel: '${side.label}边缘',
          canChange:
              _ready &&
              !_active &&
              !preview.gestureActive &&
              !_busy &&
              !_recording &&
              _identify == null,
          canToggle: !_macReceiver || !_lan.connected,
          onChanged: _toggleDragPreview,
          onClear: _clearDragPreview,
        );
      },
    ),
  );

  Widget _monitor() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _connectionPanel(),
      if (_captureSupported) ...[
        const SizedBox(height: 16),
        ValueListenableBuilder<AudioOutputInfo>(
          valueListenable: _audioOutput,
          builder: (_, info, _) => ListenableBuilder(
            listenable: _audioSync,
            builder: (_, _) => AudioOutputPanel(
              info: info,
              onRefresh: () => unawaited(_readAudioOutput()),
              mode: _settings.audioSyncMode,
              onModeChanged: (AudioSyncMode value) {
                setState(() => _settings.audioSyncMode = value);
                _persist();
                _configureAudioSync();
              },
              bufferMs: _settings.audioBufferMs,
              onBufferChanged: (value) =>
                  setState(() => _settings.audioBufferMs = value),
              onBufferChangeEnd: (value) {
                setState(() => _settings.audioBufferMs = value);
                _persist();
                _configureAudioSync();
              },
              syncStatus: _audioSync.status,
              onRetry: _audioSync.failed ? _audioSync.retry : null,
            ),
          ),
        ),
      ],
      if (_captureSupported) ...[
        const SizedBox(height: 16),
        LocalKeyPanel(
          keys: _settings.localKeys,
          enabled:
              _ready && !_active && !_busy && !_recording && _identify == null,
          onAdd: _addLocalKey,
          onRemove: _removeLocalKey,
        ),
      ],
      if (_captureSupported) ...[const SizedBox(height: 16), _dragPanel()],
      const SizedBox(height: 16),
      ControlReturnLogPanel(
        history: _returnHistory,
        active: _active,
        onClear: () => _saveReturnLog(_returnHistory.clear()),
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
