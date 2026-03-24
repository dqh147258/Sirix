import 'dart:async';
import 'dart:convert';

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
    this.sharedScreenId,
    this.lastSignalType,
    this.lastUpdated,
  });

  static const _unset = Object();

  final bool initializing;
  final bool sharing;
  final String? sessionId;
  final String? sharedScreenId;
  final String? lastSignalType;
  final DateTime? lastUpdated;

  DesktopMediaState copyWith({
    bool? initializing,
    bool? sharing,
    Object? sessionId = _unset,
    Object? sharedScreenId = _unset,
    Object? lastSignalType = _unset,
    DateTime? lastUpdated,
  }) {
    return DesktopMediaState(
      initializing: initializing ?? this.initializing,
      sharing: sharing ?? this.sharing,
      sessionId: identical(sessionId, _unset) ? this.sessionId : sessionId as String?,
      sharedScreenId: identical(sharedScreenId, _unset)
          ? this.sharedScreenId
          : sharedScreenId as String?,
      lastSignalType: identical(lastSignalType, _unset)
          ? this.lastSignalType
          : lastSignalType as String?,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}

class DesktopMediaController extends BaseViewModel<DesktopMediaState> {
  DesktopMediaController() : super(const DesktopMediaState());

  RTCPeerConnection? _peerConnection;
  RTCRtpSender? _videoSender;
  MediaStream? _displayStream;
  LocalSignalCallback? _localSignalCallback;
  String? _sharedScreenId;

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
          sharedScreenId: _sharedScreenId,
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
          sharedScreenId: _sharedScreenId,
          lastSignalType: 'desktop.closed',
          lastUpdated: DateTime.now(),
        );
      }
    };

    final displayStream = await _createDisplayStream(
      sessionId: sessionId,
      screenId: _sharedScreenId,
    );
    _displayStream = displayStream;

    for (final track in displayStream.getTracks()) {
      final sender = await peerConnection.addTrack(track, displayStream);
      if (track.kind == 'video') {
        _videoSender = sender;
      }
    }

    if (_videoSender == null) {
      throw StateError('desktop display stream missing video sender');
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
      sharedScreenId: _sharedScreenId,
      lastSignalType: 'answer.local.created',
      lastUpdated: DateTime.now(),
    );
  }

  Future<void> switchSharedScreen({
    required String sessionId,
    required String screenId,
  }) async {
    if (state.sessionId != sessionId) {
      AppLogger.warn(
        '$_mediaStreamTraceTag desktop switch ignored sessionId=$sessionId activeSessionId=${state.sessionId ?? '-'} screenId=$screenId',
      );
      return;
    }

    final videoSender = _videoSender;
    if (videoSender == null) {
      throw StateError('desktop video sender is not ready');
    }

    AppLogger.info(
      '$_mediaStreamTraceTag desktop switching shared screen sessionId=$sessionId screenId=$screenId',
    );
    final nextStream = await _createDisplayStream(
      sessionId: sessionId,
      screenId: screenId,
    );

    final nextTracks = nextStream.getVideoTracks();
    if (nextTracks.isEmpty) {
      await _disposeDisplayStream(nextStream);
      throw StateError('desktop display stream missing video track for screenId=$screenId');
    }

    final previousStream = _displayStream;
    await videoSender.replaceTrack(nextTracks.first);
    _displayStream = nextStream;
    _sharedScreenId = screenId;
    state = state.copyWith(
      sharing: true,
      sharedScreenId: screenId,
      lastSignalType: 'screen.local.switched',
      lastUpdated: DateTime.now(),
    );
    AppLogger.info(
      '$_mediaStreamTraceTag desktop shared screen switched sessionId=$sessionId screenId=$screenId trackId=${nextTracks.first.id}',
    );

    if (previousStream != null) {
      await _disposeDisplayStream(previousStream);
    }
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
    _videoSender = null;
    _sharedScreenId = null;
    if (stream != null) {
      await _disposeDisplayStream(stream);
    }

    final peerConnection = _peerConnection;
    _peerConnection = null;
    if (peerConnection != null) {
      await peerConnection.close();
    }

    state = state.copyWith(
      initializing: false,
      sharing: false,
      sessionId: null,
      sharedScreenId: null,
      lastUpdated: DateTime.now(),
    );
  }

  Future<MediaStream> _createDisplayStream({
    required String sessionId,
    required String? screenId,
  }) async {
    final sourceId = screenId == null ? null : await _resolveDesktopSourceId(screenId);
    final constraints = <String, dynamic>{
      'audio': false,
      'video': sourceId == null
          ? true
          : {
              'deviceId': {'exact': sourceId},
              'mandatory': {'frameRate': 30},
            },
    };

    AppLogger.info(
      '$_mediaStreamTraceTag desktop requesting display media sessionId=$sessionId screenId=${screenId ?? '-'} sourceId=${sourceId ?? 'default'}',
    );
    final displayStream = await navigator.mediaDevices.getDisplayMedia(constraints);
    AppLogger.info(
      '$_mediaStreamTraceTag desktop display media acquired sessionId=$sessionId screenId=${screenId ?? '-'} sourceId=${sourceId ?? 'default'} tracks=${displayStream.getTracks().length}',
    );
    return displayStream;
  }

  Future<String> _resolveDesktopSourceId(String screenId) async {
    final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
    final normalizedScreenId = _normalizeScreenId(screenId);
    final hintedSourceId = _extractLinuxSourceId(screenId);
    final hintedSourceName = _extractLinuxSourceName(screenId);

    for (final source in sources) {
      final normalizedSourceId = _normalizeScreenId(source.id);
      if (source.id == screenId || normalizedSourceId == normalizedScreenId) {
        AppLogger.info(
          '$_mediaStreamTraceTag desktop source resolved screenId=$screenId sourceId=${source.id} sourceName=${source.name}',
        );
        return source.id;
      }
    }

    if (hintedSourceId != null) {
      for (final source in sources) {
        if (source.id == hintedSourceId || _normalizeScreenId(source.id) == hintedSourceId) {
          AppLogger.info(
            '$_mediaStreamTraceTag desktop linux source resolved by id screenId=$screenId sourceId=${source.id} sourceName=${source.name}',
          );
          return source.id;
        }
      }
    }

    if (hintedSourceName != null) {
      final normalizedSourceName = _normalizeScreenId(hintedSourceName);
      for (final source in sources) {
        if (_normalizeScreenId(source.name) == normalizedSourceName) {
          AppLogger.info(
            '$_mediaStreamTraceTag desktop linux source resolved by name screenId=$screenId sourceId=${source.id} sourceName=${source.name}',
          );
          return source.id;
        }
      }
    }

    if (_isDefaultLinuxScreenId(screenId) && sources.isNotEmpty) {
      AppLogger.warn(
        '$_mediaStreamTraceTag desktop linux screen fallback to first source screenId=$screenId sourceId=${sources.first.id}',
      );
      return sources.first.id;
    }

    final availableSourceIds = sources.map((source) => source.id).join(',');
    throw StateError(
      'no desktop capture source matches screenId=$screenId available=$availableSourceIds',
    );
  }

  String _normalizeScreenId(String screenId) {
    const prefix = 'display-';
    final normalized = screenId.trim().toLowerCase();
    if (normalized.startsWith(prefix)) {
      return normalized.substring(prefix.length);
    }
    return normalized;
  }

  String? _extractLinuxSourceId(String screenId) {
    if (!screenId.startsWith('linux:')) {
      return null;
    }

    final parts = screenId.split(':');
    if (parts.length < 2 || parts[1].isEmpty) {
      return null;
    }

    return _normalizeScreenId(parts[1]);
  }

  String? _extractLinuxSourceName(String screenId) {
    if (!screenId.startsWith('linux:')) {
      return null;
    }

    final parts = screenId.split(':');
    if (parts.length < 3) {
      return null;
    }

    try {
      return utf8.decode(base64Url.decode(base64.normalize(parts.sublist(2).join(':'))));
    } catch (_) {
      return null;
    }
  }

  bool _isDefaultLinuxScreenId(String screenId) {
    return screenId == 'linux:default' || screenId == 'linux:default:';
  }

  Future<void> _disposeDisplayStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      track.stop();
    }
    await stream.dispose();
  }

  @override
  void dispose() {
    unawaited(() async {
      await stop();
    }());
    super.dispose();
  }
}

final desktopMediaControllerProvider =
    StateNotifierProvider<DesktopMediaController, DesktopMediaState>((ref) {
  return DesktopMediaController();
});
