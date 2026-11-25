import 'dart:async';
import 'package:flutter/services.dart';
import 'remote/lan_session.dart';

/// Keeps one Mac-origin press alive independently of pointer capture. Every
/// lease and resume is tied to both an opaque token and the original press ID.
class ReceiverDragHold {
  ReceiverDragHold(this.session, this.channel, {required this.supported}) {
    session.receiverDragHoldSupported = supported;
    session.onReceiverDragControl = _receive;
    session.addListener(_connectionChanged);
    _connectionChanged();
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_poll()),
    );
  }
  final LanSession session;
  final MethodChannel channel;
  final bool supported;
  Map<String, dynamic>? _hold;
  Timer? _timer;
  bool _polling = false, _disposed = false;
  int _generation = -1;

  static Map<String, dynamic>? parse(dynamic value) {
    if (value is! Map) return null;
    final token = value['token'],
        button = value['button'],
        press = value['pressId'];
    if (token is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(token) ||
        button is! int ||
        (button != 0 && button != 1) ||
        press is! int ||
        press <= 0 ||
        press > 0x1fffffffffffff) {
      return null;
    }
    return {'token': token, 'button': button, 'pressId': press};
  }

  void _connectionChanged() {
    if (_generation == session.connectionGeneration && session.connected) {
      return;
    }
    _generation = session.connectionGeneration;
    final old = _hold;
    _hold = null;
    if (old != null && session.receiving) {
      unawaited(
        channel
            .invokeMethod<void>('receiverDragCancel', old)
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _send(Map<String, dynamic> message) async {
    try {
      await session.sendReceiverDragControl(message);
    } catch (_) {
      // Native timeout remains authoritative if the control stream stalls.
    }
  }

  Future<void> nativeStopped(dynamic state, int generation) async {
    final hold = parse(state is Map ? state['suspended'] : null);
    if (hold == null) return;
    if (_disposed ||
        generation != session.connectionGeneration ||
        !session.receiving ||
        !session.connected ||
        !session.supportsReceiverDragHold) {
      await channel.invokeMethod<void>('receiverDragCancel', hold);
      return;
    }
    _hold = hold;
    await _send({'type': 'receiverDragSuspended', ...hold});
  }

  Future<void> nativeEnded(String token) async {
    if (_hold?['token'] != token) return;
    _hold = null;
    await _send({'type': 'receiverDragEnded', 'token': token});
  }

  void nativeBegan() {
    if (!session.receiving) return;
    final old = _hold;
    _hold = null;
    if (old != null) {
      unawaited(_send({'type': 'receiverDragEnded', 'token': old['token']}));
    }
  }

  Future<void> _receive(Map<String, dynamic> message) async {
    if (_disposed || !session.supportsReceiverDragHold) return;
    if (message['type'] == 'receiverDragSuspended' && !session.receiving) {
      final hold = parse(message);
      if (hold == null) return;
      _hold = hold;
      unawaited(_poll());
    } else if (message['type'] == 'receiverDragLease' && session.receiving) {
      final hold = parse(message);
      if (hold == null ||
          _hold?['token'] != hold['token'] ||
          message['held'] is! bool) {
        return;
      }
      await channel.invokeMethod<void>('receiverDragLease', {
        ...hold,
        'held': message['held'],
      });
    } else if (message['type'] == 'receiverDragEnded' &&
        !session.receiving &&
        _hold?['token'] == message['token']) {
      _hold = null;
    } else if (message['type'] == 'receiverDragResumed' && session.receiving) {
      final hold = parse(message);
      if (hold != null) {
        await channel.invokeMethod<void>('receiverDragResumed', hold);
      }
    }
  }

  Future<bool> _stillHeld(Map<String, dynamic> hold) async {
    final state = await channel.invokeMapMethod<String, dynamic>(
      'receiverDragButtons',
    );
    final button = hold['button'] as int;
    return state?['healthy'] == true &&
        state?['buttons'] == 1 << button &&
        state?[button == 0 ? 'leftPress' : 'rightPress'] == hold['pressId'];
  }

  Future<void> _poll() async {
    if (_disposed ||
        _polling ||
        session.receiving ||
        !session.connected ||
        !session.supportsReceiverDragHold ||
        _hold == null) {
      return;
    }
    _polling = true;
    final hold = _hold!;
    final generation = session.connectionGeneration;
    try {
      var held = false;
      try {
        held = await _stillHeld(hold);
      } catch (_) {
        /* fail closed */
      }
      if (_disposed ||
          generation != session.connectionGeneration ||
          _hold?['token'] != hold['token']) {
        return;
      }
      await _send({'type': 'receiverDragLease', ...hold, 'held': held});
      if (!held && _hold?['token'] == hold['token']) _hold = null;
    } finally {
      _polling = false;
    }
  }

  Future<Map<String, dynamic>?> prepareResume() async {
    final hold = _hold;
    if (hold == null ||
        session.receiving ||
        !session.connected ||
        !session.supportsReceiverDragHold) {
      return null;
    }
    final generation = session.connectionGeneration;
    bool held;
    try {
      held = await _stillHeld(hold);
    } catch (_) {
      held = false;
    }
    if (_disposed ||
        generation != session.connectionGeneration ||
        _hold?['token'] != hold['token']) {
      return null;
    }
    if (!held) {
      await _send({'type': 'receiverDragLease', ...hold, 'held': false});
      if (_hold?['token'] == hold['token']) _hold = null;
      return null;
    }
    return Map.of(hold);
  }

  Future<Map<String, dynamic>?> beginCapture({
    double? edgeEntryY,
    String edgeEntrySide = 'left',
    bool allowResume = false,
    bool Function()? allowed,
  }) async {
    var resume = allowResume ? await prepareResume() : null;
    Future<void> begin() => session.beginCapture(
      edgeEntryY: edgeEntryY,
      edgeEntrySide: edgeEntrySide,
      receiverDragResume: resume,
    );
    try {
      await begin();
    } catch (_) {
      // A fast return can send Begin before the suspension notice arrives.
      // The receiver sends its notice before rejecting that Begin. Retry once
      // in the same flow, after checking the still-held physical press again.
      if (resume != null ||
          !allowResume ||
          !session.connected ||
          (allowed != null && !allowed())) {
        rethrow;
      }
      resume = await prepareResume();
      if (resume == null) {
        rethrow;
      }
      await begin();
    }
    return resume;
  }

  Future<void> confirmResume(Map<String, dynamic>? resume) async {
    if (resume != null && !session.receiving) {
      await _send({'type': 'receiverDragResumed', ...resume});
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    final old = _hold;
    _hold = null;
    if (old != null && session.receiving) {
      unawaited(
        channel
            .invokeMethod<void>('receiverDragCancel', old)
            .catchError((Object _) {}),
      );
    }
    session.removeListener(_connectionChanged);
    session.onReceiverDragControl = null;
  }
}
