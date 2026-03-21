import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'remote_stream_controller.dart';

const _mediaStreamTraceTag = '[MEDIA_STREAM_TRACE]';

@immutable
class DesktopMediaState {
  const DesktopMediaState({
    this.initializing = false,
    this.sharing = false,
    this.sessionId,
    this.lastSignalType,
    this.lastUpdated,
  });

  final bool initializing;
  final bool sharing;
  final String? sessionId;
  final String? lastSignalType;
  final DateTime? lastUpdated;

  DesktopMediaState copyWith({
    bool? initializing,
    bool? sharing,
    String? sessionId,
    String? lastSignalType,
    DateTime? lastUpdated,
  }) {
    return DesktopMediaState(
      initializing: initializing ?? this.initializing,
      sharing: sharing ?? this.sharing,
      sessionId: sessionId ?? this.sessionId,
      lastSignalType: lastSignalType ?? this.lastSignalType,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}

class DesktopMediaController extends BaseViewModel<DesktopMediaState> {
  DesktopMediaController() : super(const DesktopMediaState());

  RTCPeerConnection? _peerConnection;
  MediaStream? _displayStream;
  RTCVideoRenderer? _localRenderer;
  LocalSignalCallback? _localSignalCallback;

  RTCVideoRenderer? get localRenderer => _localRenderer;

  Future<void> startAnswering({
    required String sessionId,
    required String remoteOfferSdp,
    required LocalSignalCallback onLocalSignal,
  }) async {
    await stop();

    state = state.copyWith(
      initializing: true,
      sessionId: sessionId,
      lastUpdated: DateTime.now(),
    );
    _localSignalCallback = onLocalSignal;

    if (_localRenderer == null) {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      _localRenderer = renderer;
    }

    final peerConnection = await createPeerConnection(defaultRtcConfiguration());
    AppLogger.info(
      '$_mediaStreamTraceTag desktop peer connection created sessionId=$sessionId',
    );
    peerConnection.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) {
        return;
      }

      final callback = _localSignalCallback;
      if (callback == null) {
        return;
      }

      unawaited(
        callback(
          WebrtcSignalType.iceCandidate,
          candidate: iceCandidateToMap(candidate),
        ),
      );
      AppLogger.trace(
        '$_mediaStreamTraceTag desktop local ice candidate emitted sessionId=$sessionId mid=${candidate.sdpMid} mline=${candidate.sdpMLineIndex}',
      );
    };

    peerConnection.onConnectionState = (connectionState) {
      AppLogger.info('desktop peer connection state: $connectionState');
      if (connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        state = state.copyWith(
          sharing: true,
          initializing: false,
          lastSignalType: 'desktop.connected',
          lastUpdated: DateTime.now(),
        );
        return;
      }

      if (connectionState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          connectionState == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          connectionState == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        state = state.copyWith(
          sharing: false,
          initializing: false,
          lastSignalType: 'desktop.closed',
          lastUpdated: DateTime.now(),
        );
      }
    };

    AppLogger.info(
      '$_mediaStreamTraceTag desktop requesting display media sessionId=$sessionId',
    );
    final displayStream = await navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': true,
    });
    AppLogger.info(
      '$_mediaStreamTraceTag desktop display media acquired sessionId=$sessionId tracks=${displayStream.getTracks().length}',
    );
    _displayStream = displayStream;
    _localRenderer?.srcObject = displayStream;

    for (final track in displayStream.getTracks()) {
      await peerConnection.addTrack(track, displayStream);
    }

    await peerConnection.setRemoteDescription(
      RTCSessionDescription(remoteOfferSdp, 'offer'),
    );
    final answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);

    _peerConnection = peerConnection;
    await onLocalSignal(WebrtcSignalType.answer, sdp: answer.sdp ?? '');
    AppLogger.info(
      '$_mediaStreamTraceTag desktop local answer created sessionId=$sessionId length=${answer.sdp?.length ?? 0}',
    );
    state = state.copyWith(
      initializing: false,
      sharing: true,
      sessionId: sessionId,
      lastSignalType: 'answer.local.created',
      lastUpdated: DateTime.now(),
    );
  }

  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      return;
    }

    await peerConnection.addCandidate(
      RTCIceCandidate(
        candidate['candidate'] as String?,
        candidate['sdpMid'] as String?,
        candidate['sdpMLineIndex'] as int?,
      ),
    );

    state = state.copyWith(
      lastSignalType: 'candidate.remote.applied',
      lastUpdated: DateTime.now(),
    );
  }

  Future<void> stop() async {
    final stream = _displayStream;
    _displayStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      await stream.dispose();
    }

    _localRenderer?.srcObject = null;

    final peerConnection = _peerConnection;
    _peerConnection = null;
    if (peerConnection != null) {
      await peerConnection.close();
    }

    state = state.copyWith(
      initializing: false,
      sharing: false,
      sessionId: null,
      lastUpdated: DateTime.now(),
    );
  }

  @override
  void dispose() {
    unawaited(() async {
      await stop();
      await _localRenderer?.dispose();
      _localRenderer = null;
    }());
    super.dispose();
  }
}

final desktopMediaControllerProvider =
    StateNotifierProvider<DesktopMediaController, DesktopMediaState>((ref) {
  return DesktopMediaController();
});
