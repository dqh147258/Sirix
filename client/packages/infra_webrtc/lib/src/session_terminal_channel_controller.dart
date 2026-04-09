import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:app_core/app_core.dart';

const String sessionTerminalChannelLabel = 'sirix-terminal-v1';
const int _terminalChannelBufferedAmountLowThreshold = 64 * 1024;

enum SessionTerminalChannelRole {
  mobile,
  desktop,
}

@immutable
class SessionTerminalChannelState {
  const SessionTerminalChannelState({
    this.sessionId,
    this.role,
    this.ready = false,
    this.bufferedAmount = 0,
    this.lastError,
  });

  final String? sessionId;
  final SessionTerminalChannelRole? role;
  final bool ready;
  final int bufferedAmount;
  final String? lastError;

  SessionTerminalChannelState copyWith({
    Object? sessionId = _unset,
    Object? role = _unset,
    bool? ready,
    int? bufferedAmount,
    Object? lastError = _unset,
  }) {
    return SessionTerminalChannelState(
      sessionId: identical(sessionId, _unset) ? this.sessionId : sessionId as String?,
      role: identical(role, _unset) ? this.role : role as SessionTerminalChannelRole?,
      ready: ready ?? this.ready,
      bufferedAmount: bufferedAmount ?? this.bufferedAmount,
      lastError: identical(lastError, _unset) ? this.lastError : lastError as String?,
    );
  }

  static const Object _unset = Object();
}

class SessionTerminalChannelController extends BaseViewModel<SessionTerminalChannelState> {
  SessionTerminalChannelController() : super(const SessionTerminalChannelState());

  RTCDataChannel? _channel;
  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messages.stream;

  bool isReadyForSession(String sessionId) {
    return state.ready && state.sessionId == sessionId;
  }

  Future<void> bindMobilePeerConnection({
    required String sessionId,
    required RTCPeerConnection peerConnection,
  }) async {
    final existingChannel = _channel;
    if (state.sessionId == sessionId &&
        state.role == SessionTerminalChannelRole.mobile &&
        existingChannel != null) {
      return;
    }

    await _disposeChannel();

    final init = RTCDataChannelInit()
      ..ordered = true
      ..protocol = 'sirix-terminal'
      ..binaryType = 'text';
    final channel = await peerConnection.createDataChannel(
      sessionTerminalChannelLabel,
      init,
    );
    _bindChannel(
      channel,
      sessionId: sessionId,
      role: SessionTerminalChannelRole.mobile,
    );
  }

  void bindDesktopPeerConnection({
    required String sessionId,
    required RTCPeerConnection peerConnection,
  }) {
    if (state.sessionId != sessionId || state.role != SessionTerminalChannelRole.desktop) {
      state = state.copyWith(
        sessionId: sessionId,
        role: SessionTerminalChannelRole.desktop,
        ready: false,
        bufferedAmount: 0,
        lastError: null,
      );
    }

    peerConnection.onDataChannel = (channel) {
      if (channel.label != sessionTerminalChannelLabel) {
        return;
      }

      unawaited(_disposeChannel());
      _bindChannel(
        channel,
        sessionId: sessionId,
        role: SessionTerminalChannelRole.desktop,
      );
    };
  }

  Future<bool> sendJson(Map<String, dynamic> payload) async {
    final channel = _channel;
    if (!state.ready || channel == null) {
      return false;
    }

    try {
      await channel.send(RTCDataChannelMessage(jsonEncode(payload)));
      final bufferedAmount = await channel.getBufferedAmount();
      state = state.copyWith(
        bufferedAmount: bufferedAmount,
        lastError: null,
      );
      return true;
    } catch (error) {
      AppLogger.warn('terminal data channel send failed error=$error');
      state = state.copyWith(lastError: error.toString());
      return false;
    }
  }

  Future<void> reset() async {
    await _disposeChannel();
    state = const SessionTerminalChannelState();
  }

  void _bindChannel(
    RTCDataChannel channel, {
    required String sessionId,
    required SessionTerminalChannelRole role,
  }) {
    _channel = channel;
    channel.bufferedAmountLowThreshold = _terminalChannelBufferedAmountLowThreshold;
    channel.onBufferedAmountChange = (currentAmount, _) {
      state = state.copyWith(bufferedAmount: currentAmount);
    };
    channel.onBufferedAmountLow = (currentAmount) {
      state = state.copyWith(bufferedAmount: currentAmount);
    };
    channel.onDataChannelState = (nextState) {
      final ready = nextState == RTCDataChannelState.RTCDataChannelOpen;
      state = state.copyWith(
        sessionId: sessionId,
        role: role,
        ready: ready,
        lastError: ready ? null : state.lastError,
      );
      AppLogger.info(
        'terminal data channel state sessionId=$sessionId role=${role.name} state=$nextState',
      );
    };
    channel.onMessage = (message) {
      if (message.isBinary) {
        AppLogger.warn('terminal data channel ignored binary message');
        return;
      }

      final decoded = _decodeJson(message.text);
      if (decoded == null) {
        return;
      }

      _messages.add(decoded);
    };

    state = state.copyWith(
      sessionId: sessionId,
      role: role,
      ready: channel.state == RTCDataChannelState.RTCDataChannelOpen,
      bufferedAmount: channel.bufferedAmount ?? 0,
      lastError: null,
    );
  }

  Map<String, dynamic>? _decodeJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (error) {
      AppLogger.warn('terminal data channel decode failed error=$error');
    }
    return null;
  }

  Future<void> _disposeChannel() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        await channel.close();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    unawaited(_disposeChannel());
    unawaited(_messages.close());
    super.dispose();
  }
}

final sessionTerminalChannelControllerProvider = StateNotifierProvider<
    SessionTerminalChannelController, SessionTerminalChannelState>((ref) {
  return SessionTerminalChannelController();
});
