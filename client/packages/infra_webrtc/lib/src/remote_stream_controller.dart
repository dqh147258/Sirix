import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'session_terminal_channel_controller.dart';

typedef LocalSignalCallback = Future<void> Function(
  WebrtcSignalType signalType, {
  String? sdp,
  Map<String, dynamic>? candidate,
});

const _mediaStreamTraceTag = '[MEDIA_STREAM_TRACE]';

enum QualityProfile {
  p480,
  p720,
  p1080,
}

@immutable
class RemoteStreamState {
  const RemoteStreamState({
    this.connected = false,
    this.remoteVideoActive = false,
    this.autoQuality = true,
    this.qualityProfile = QualityProfile.p720,
    this.lastSignalType,
    this.lastUpdated,
  });

  final bool connected;
  final bool remoteVideoActive;
  final bool autoQuality;
  final QualityProfile qualityProfile;
  final String? lastSignalType;
  final DateTime? lastUpdated;

  RemoteStreamState copyWith({
    bool? connected,
    bool? remoteVideoActive,
    bool? autoQuality,
    QualityProfile? qualityProfile,
    String? lastSignalType,
    DateTime? lastUpdated,
  }) {
    return RemoteStreamState(
      connected: connected ?? this.connected,
      remoteVideoActive: remoteVideoActive ?? this.remoteVideoActive,
      autoQuality: autoQuality ?? this.autoQuality,
      qualityProfile: qualityProfile ?? this.qualityProfile,
      lastSignalType: lastSignalType ?? this.lastSignalType,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}

class RemoteStreamController extends BaseViewModel<RemoteStreamState> {
  RemoteStreamController({
    required SessionTerminalChannelController terminalChannelController,
  })  : _terminalChannelController = terminalChannelController,
        super(const RemoteStreamState());

  RTCPeerConnection? _peerConnection;
  RTCVideoRenderer? _remoteRenderer;
  LocalSignalCallback? _localSignalCallback;
  final SessionTerminalChannelController _terminalChannelController;

  RTCVideoRenderer? get remoteRenderer => _remoteRenderer;

  Future<void> connect({
    required LocalSignalCallback onLocalSignal,
  }) async {
    _localSignalCallback = onLocalSignal;

    if (_remoteRenderer == null) {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      _remoteRenderer = renderer;
    }

    if (_peerConnection != null) {
      state = state.copyWith(connected: true, lastUpdated: DateTime.now());
      return;
    }

    final peerConnection = await createPeerConnection(defaultRtcConfiguration());
    AppLogger.info('$_mediaStreamTraceTag mobile peer connection created');
    await peerConnection.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
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
        '$_mediaStreamTraceTag mobile local ice candidate emitted mid=${candidate.sdpMid} mline=${candidate.sdpMLineIndex}',
      );
    };

    peerConnection.onTrack = (event) {
      final stream = event.streams.isNotEmpty ? event.streams.first : null;
      if (stream != null) {
        _remoteRenderer?.srcObject = stream;
      }
      AppLogger.info(
        '$_mediaStreamTraceTag mobile remote track received kind=${event.track.kind} streams=${event.streams.length}',
      );
      state = state.copyWith(
        remoteVideoActive: true,
        lastSignalType: 'track.remote.received',
        lastUpdated: DateTime.now(),
      );
    };

    peerConnection.onConnectionState = (connectionState) {
      AppLogger.info('remote peer connection state: $connectionState');
      if (connectionState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          connectionState == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          connectionState == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        state = state.copyWith(
          connected: false,
          remoteVideoActive: false,
          lastUpdated: DateTime.now(),
        );
      }
    };

    _peerConnection = peerConnection;
    AppLogger.info('connect remote stream');
    state = state.copyWith(connected: true, lastUpdated: DateTime.now());
  }

  Future<void> disconnect() async {
    AppLogger.info('disconnect remote stream');

    final renderer = _remoteRenderer;
    if (renderer != null) {
      renderer.srcObject = null;
    }

    final peerConnection = _peerConnection;
    _peerConnection = null;
    if (peerConnection != null) {
      await peerConnection.close();
    }
    await _terminalChannelController.reset();

    state = state.copyWith(
      connected: false,
      remoteVideoActive: false,
      lastUpdated: DateTime.now(),
    );
  }

  Future<void> setAutoQuality(bool value) async {
    state = state.copyWith(autoQuality: value, lastUpdated: DateTime.now());
  }

  Future<void> setQualityProfile(QualityProfile profile) async {
    state = state.copyWith(
      autoQuality: false,
      qualityProfile: profile,
      lastUpdated: DateTime.now(),
    );
  }

  Future<String> createOffer({
    required String sessionId,
  }) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('peer connection is not ready');
    }

    await _terminalChannelController.bindMobilePeerConnection(
      sessionId: sessionId,
      peerConnection: peerConnection,
    );
    final offer = await peerConnection.createOffer();
    await peerConnection.setLocalDescription(offer);
    AppLogger.info(
      '$_mediaStreamTraceTag mobile local offer created length=${offer.sdp?.length ?? 0}',
    );

    state = state.copyWith(lastSignalType: 'offer.local.created', lastUpdated: DateTime.now());
    return offer.sdp ?? '';
  }

  Future<String> createAnswerForOffer(
    String remoteOffer, {
    required String sessionId,
  }) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('peer connection is not ready');
    }

    await _terminalChannelController.bindMobilePeerConnection(
      sessionId: sessionId,
      peerConnection: peerConnection,
    );
    await peerConnection.setRemoteDescription(
      RTCSessionDescription(remoteOffer, 'offer'),
    );

    final answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);
    AppLogger.info(
      '$_mediaStreamTraceTag mobile local answer created length=${answer.sdp?.length ?? 0}',
    );

    state = state.copyWith(lastSignalType: 'answer.local.created', lastUpdated: DateTime.now());
    return answer.sdp ?? '';
  }

  Future<void> applyRemoteAnswer(String sdp) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('peer connection is not ready');
    }

    await peerConnection.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );

    AppLogger.info(
      '$_mediaStreamTraceTag mobile remote answer applied length=${sdp.length}',
    );
    AppLogger.info('apply remote answer length=${sdp.length}');
    state = state.copyWith(lastSignalType: 'answer.remote.applied', lastUpdated: DateTime.now());
  }

  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('peer connection is not ready');
    }

    await peerConnection.addCandidate(
      RTCIceCandidate(
        candidate['candidate'] as String?,
        candidate['sdpMid'] as String?,
        candidate['sdpMLineIndex'] as int?,
      ),
    );

    AppLogger.trace(
      '$_mediaStreamTraceTag mobile remote ice candidate applied mid=${candidate['sdpMid']} mline=${candidate['sdpMLineIndex']}',
    );
    AppLogger.trace('apply remote candidate: $candidate');
    state = state.copyWith(lastSignalType: 'candidate.remote.applied', lastUpdated: DateTime.now());
  }

  @override
  void dispose() {
    unawaited(() async {
      await disconnect();
      await _remoteRenderer?.dispose();
      _remoteRenderer = null;
    }());
    super.dispose();
  }
}

Map<String, dynamic> defaultRtcConfiguration() {
  return {
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
        ],
      },
    ],
    'sdpSemantics': 'unified-plan',
  };
}

Map<String, dynamic> iceCandidateToMap(RTCIceCandidate candidate) {
  return {
    'candidate': candidate.candidate,
    'sdpMid': candidate.sdpMid,
    'sdpMLineIndex': candidate.sdpMLineIndex,
  };
}

final remoteStreamControllerProvider =
    StateNotifierProvider<RemoteStreamController, RemoteStreamState>((ref) {
  final terminalChannelController = ref.watch(
    sessionTerminalChannelControllerProvider.notifier,
  );
  return RemoteStreamController(
    terminalChannelController: terminalChannelController,
  );
});
