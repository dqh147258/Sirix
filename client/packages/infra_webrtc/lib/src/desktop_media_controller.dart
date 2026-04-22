import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'remote_stream_controller.dart';
import 'session_terminal_channel_controller.dart';

const _mediaStreamTraceTag = '[MEDIA_STREAM_TRACE]';

enum DesktopCaptureFrameRatePreset {
  fps15,
  fps20,
  fps30,
}

extension DesktopCaptureFrameRatePresetValue on DesktopCaptureFrameRatePreset {
  int get value {
    switch (this) {
      case DesktopCaptureFrameRatePreset.fps15:
        return 15;
      case DesktopCaptureFrameRatePreset.fps20:
        return 20;
      case DesktopCaptureFrameRatePreset.fps30:
        return 30;
    }
  }
}

@immutable
class DesktopMediaState {
  const DesktopMediaState({
    this.initializing = false,
    this.sharing = false,
    this.sessionId,
    this.sharedScreenId,
    this.captureFrameRate = 20,
    this.lastSignalType,
    this.lastUpdated,
  });

  static const _unset = Object();

  final bool initializing;
  final bool sharing;
  final String? sessionId;
  final String? sharedScreenId;
  final int? captureFrameRate;
  final String? lastSignalType;
  final DateTime? lastUpdated;

  DesktopMediaState copyWith({
    bool? initializing,
    bool? sharing,
    Object? sessionId = _unset,
    Object? sharedScreenId = _unset,
    Object? captureFrameRate = _unset,
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
      captureFrameRate: identical(captureFrameRate, _unset)
          ? this.captureFrameRate
          : captureFrameRate as int?,
      lastSignalType: identical(lastSignalType, _unset)
          ? this.lastSignalType
          : lastSignalType as String?,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}

class DesktopMediaController extends BaseViewModel<DesktopMediaState> {
  DesktopMediaController({
    required SessionTerminalChannelController terminalChannelController,
  })  : _terminalChannelController = terminalChannelController,
        super(const DesktopMediaState());

  RTCPeerConnection? _peerConnection;
  RTCRtpSender? _videoSender;
  MediaStream? _displayStream;
  LocalSignalCallback? _localSignalCallback;
  final SessionTerminalChannelController _terminalChannelController;
  String? _sharedScreenId;
  QualityProfile _preferredQualityProfile = QualityProfile.p720;
  final List<Map<String, dynamic>> _pendingLocalIceCandidates = <Map<String, dynamic>>[];
  final Set<String> _pendingLocalIceKeys = <String>{};
  Future<void>? _rtcWarmupFuture;
  bool _bufferLocalIceCandidates = false;
  bool _drainingLocalIceCandidates = false;
  String? _localIceSessionId;

  Future<void> warmUpRtc() {
    final existing = _rtcWarmupFuture;
    if (existing != null) {
      return existing;
    }

    final future = _performRtcWarmUp();
    _rtcWarmupFuture = future;
    return future;
  }

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
    _beginBufferingLocalIceCandidates(sessionId);

    // Desktop 端首个 PeerConnection 常有明显冷启动开销（底层工厂/编解码器/
    // 线程池初始化都可能发生在这里）。提前预热后，这里的真实建连路径只需
    // 等待一次已完成的 warmup future，可显著降低首连抖动。
    await warmUpRtc();
    final createPeerConnectionStopwatch = Stopwatch()..start();
    final peerConnection = await createPeerConnection(defaultRtcConfiguration());
    createPeerConnectionStopwatch.stop();
    AppLogger.info(
      '$_mediaStreamTraceTag desktop peer connection created sessionId=$sessionId elapsed_ms=${createPeerConnectionStopwatch.elapsedMilliseconds}',
    );
    _terminalChannelController.bindDesktopPeerConnection(
      sessionId: sessionId,
      peerConnection: peerConnection,
    );
    peerConnection.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) {
        return;
      }

      _enqueueOrDispatchLocalIceCandidate(iceCandidateToMap(candidate));
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
    await _releaseBufferedLocalIceCandidates();
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
    await _replaceSharedStream(
      sessionId: sessionId,
      screenId: screenId,
      signalLabel: 'screen.local.switched',
    );
  }

  Future<void> setPreferredQualityProfile({
    required String sessionId,
    QualityProfile? profile,
  }) async {
    _preferredQualityProfile = profile ?? QualityProfile.p720;
    final frameRate = _captureFrameRateForProfile(_preferredQualityProfile).value;
    AppLogger.info(
      '$_mediaStreamTraceTag desktop preferred capture profile updated sessionId=$sessionId profile=${_preferredQualityProfile.name}',
    );
    state = state.copyWith(
      captureFrameRate: frameRate,
      lastUpdated: DateTime.now(),
    );

    if (state.sessionId != sessionId || _videoSender == null) {
      return;
    }

    await _replaceSharedStream(
      sessionId: sessionId,
      screenId: _sharedScreenId,
      signalLabel: 'quality.local.updated',
    );
  }

  Future<void> _replaceSharedStream({
    required String sessionId,
    required String? screenId,
    required String signalLabel,
  }) async {
    final videoSender = _videoSender;
    if (videoSender == null) {
      throw StateError('desktop video sender is not ready');
    }

    final nextStream = await _createDisplayStream(
      sessionId: sessionId,
      screenId: screenId,
    );
    final nextTracks = nextStream.getVideoTracks();
    if (nextTracks.isEmpty) {
      await _disposeDisplayStream(nextStream);
      throw StateError('desktop display stream missing video track');
    }

    final previousStream = _displayStream;
    await videoSender.replaceTrack(nextTracks.first);
    _displayStream = nextStream;
    _sharedScreenId = screenId;
    final frameRate = _captureFrameRateForProfile(_preferredQualityProfile).value;
    state = state.copyWith(
      sharing: true,
      sharedScreenId: screenId,
      captureFrameRate: frameRate,
      lastSignalType: signalLabel,
      lastUpdated: DateTime.now(),
    );
    AppLogger.info(
      '$_mediaStreamTraceTag desktop shared stream replaced sessionId=$sessionId screenId=${screenId ?? '-'} trackId=${nextTracks.first.id} fps=${_captureFrameRateForProfile(_preferredQualityProfile).value} signalLabel=$signalLabel',
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
    _resetLocalIceDispatchState();
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
    await _terminalChannelController.reset();

    state = state.copyWith(
      initializing: false,
      sharing: false,
      sessionId: null,
      sharedScreenId: null,
      captureFrameRate: null,
      lastUpdated: DateTime.now(),
    );
  }

  Future<MediaStream> _createDisplayStream({
    required String sessionId,
    required String? screenId,
  }) async {
    final sourceId = screenId == null ? null : await _resolveDesktopSourceId(screenId);
    final frameRate = _captureFrameRateForProfile(_preferredQualityProfile).value;
    final constraints = <String, dynamic>{
      'audio': false,
      'video': sourceId == null
          ? {
              'frameRate': {
                'ideal': frameRate,
                'max': frameRate,
              },
            }
          : {
              'deviceId': {'exact': sourceId},
              'frameRate': {
                'ideal': frameRate,
                'max': frameRate,
              },
              'mandatory': {'frameRate': frameRate},
            },
    };

    AppLogger.info(
      '$_mediaStreamTraceTag desktop requesting display media sessionId=$sessionId screenId=${screenId ?? '-'} sourceId=${sourceId ?? 'default'} fps=$frameRate profile=${_preferredQualityProfile.name}',
    );
    final displayStream = await navigator.mediaDevices.getDisplayMedia(constraints);
    AppLogger.info(
      '$_mediaStreamTraceTag desktop display media acquired sessionId=$sessionId screenId=${screenId ?? '-'} sourceId=${sourceId ?? 'default'} tracks=${displayStream.getTracks().length} fps=$frameRate',
    );
    return displayStream;
  }

  DesktopCaptureFrameRatePreset _captureFrameRateForProfile(QualityProfile profile) {
    switch (profile) {
      case QualityProfile.p480:
        return DesktopCaptureFrameRatePreset.fps15;
      case QualityProfile.p1080:
        return DesktopCaptureFrameRatePreset.fps30;
      case QualityProfile.p720:
        return DesktopCaptureFrameRatePreset.fps20;
    }
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

  Future<void> _performRtcWarmUp() async {
    final stopwatch = Stopwatch()..start();
    try {
      // 这里只做一次最小化的 create/close 预热，主动把 flutter_webrtc
      // 的惰性初始化搬到“桌面端空闲阶段”，避免首次真实远控连接时再承受
      // 这段冷启动成本。
      final peerConnection = await createPeerConnection(defaultRtcConfiguration());
      await peerConnection.close();
      stopwatch.stop();
      AppLogger.info(
        '$_mediaStreamTraceTag desktop rtc warmup completed elapsed_ms=${stopwatch.elapsedMilliseconds}',
      );
    } catch (error) {
      stopwatch.stop();
      // 预热失败不能影响后续真实建连，因此只记录并允许下次重试。
      _rtcWarmupFuture = null;
      AppLogger.warn(
        '$_mediaStreamTraceTag desktop rtc warmup failed elapsed_ms=${stopwatch.elapsedMilliseconds} error=$error',
      );
      rethrow;
    }
  }

  @override
  void dispose() {
    unawaited(() async {
      await stop();
    }());
    super.dispose();
  }
}

extension on DesktopMediaController {
  void _beginBufferingLocalIceCandidates(String sessionId) {
    // 先缓存本地 candidate，确保 desktop 侧的 answer 先送到 mobile；
    // 否则 candidate 先抢占链路，会让 answer/offer 主信令被拖慢。
    _bufferLocalIceCandidates = true;
    _localIceSessionId = sessionId;
    _pendingLocalIceCandidates.clear();
    _pendingLocalIceKeys.clear();
  }

  void _resetLocalIceDispatchState() {
    _bufferLocalIceCandidates = false;
    _drainingLocalIceCandidates = false;
    _localIceSessionId = null;
    _pendingLocalIceCandidates.clear();
    _pendingLocalIceKeys.clear();
  }

  void _enqueueOrDispatchLocalIceCandidate(Map<String, dynamic> candidate) {
    final callback = _localSignalCallback;
    final sessionId = _localIceSessionId;
    if (callback == null || sessionId == null) {
      return;
    }

    final key = _localIceCandidateKey(candidate);
    if (!_pendingLocalIceKeys.add(key)) {
      return;
    }
    _pendingLocalIceCandidates.add(candidate);
    if (_bufferLocalIceCandidates || _drainingLocalIceCandidates) {
      return;
    }
    unawaited(_drainPendingLocalIceCandidates());
  }

  Future<void> _releaseBufferedLocalIceCandidates() async {
    _bufferLocalIceCandidates = false;
    await _drainPendingLocalIceCandidates();
  }

  Future<void> _drainPendingLocalIceCandidates() async {
    final callback = _localSignalCallback;
    final sessionId = _localIceSessionId;
    if (callback == null || sessionId == null || _drainingLocalIceCandidates) {
      return;
    }

    _drainingLocalIceCandidates = true;
    try {
      // 串行发送 candidate，避免一次性并发打到 backend/mobile，
      // 造成事件流堆积和 offer/answer 被后续 candidate 噪音淹没。
      while (!_bufferLocalIceCandidates && _pendingLocalIceCandidates.isNotEmpty) {
        final candidate = _pendingLocalIceCandidates.removeAt(0);
        _pendingLocalIceKeys.remove(_localIceCandidateKey(candidate));
        await callback(
          WebrtcSignalType.iceCandidate,
          candidate: candidate,
        );
      }
    } finally {
      _drainingLocalIceCandidates = false;
      if (!_bufferLocalIceCandidates && _pendingLocalIceCandidates.isNotEmpty) {
        unawaited(_drainPendingLocalIceCandidates());
      }
    }
  }

  String _localIceCandidateKey(Map<String, dynamic> candidate) {
    return [
      candidate['candidate'] ?? '',
      candidate['sdpMid'] ?? '',
      candidate['sdpMLineIndex'] ?? '',
    ].join('|');
  }
}

final desktopMediaControllerProvider =
    StateNotifierProvider<DesktopMediaController, DesktopMediaState>((ref) {
  final terminalChannelController = ref.watch(
    sessionTerminalChannelControllerProvider.notifier,
  );
  return DesktopMediaController(
    terminalChannelController: terminalChannelController,
  );
});
