import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'remote_view_state.dart';

const _mediaStreamTraceTag = '[MEDIA_STREAM_TRACE]';

class RemoteViewViewModel extends BaseViewModel<RemoteViewState> {
  RemoteViewViewModel({
    required BackendApiClient apiClient,
    required BackendEventClient? eventClient,
    required RemoteStreamController streamController,
  })  : _apiClient = apiClient,
        _eventClient = eventClient,
        _streamController = streamController,
        super(const RemoteViewState());

  final BackendApiClient _apiClient;
  final BackendEventClient? _eventClient;
  final RemoteStreamController _streamController;

  Timer? _backgroundTimer;
  Timer? _snapshotRefreshTimer;
  WebSocketChannel? _eventChannel;
  StreamSubscription<dynamic>? _eventSubscription;
  String? _boundAccessToken;
  bool _initialOfferSent = false;

  Future<void> attachSession({
    required String sessionId,
    required String deviceId,
    required String accessToken,
    required String initialState,
  }) async {
    AppLogger.info(
      'attach remote session sessionId=$sessionId deviceId=$deviceId initialState=$initialState',
    );
    _boundAccessToken = accessToken;
    _initialOfferSent = false;
    state = state.copyWith(
      sessionId: sessionId,
      deviceId: deviceId,
      sessionState: initialState,
      loading: true,
      clearError: true,
    );

    await _streamController.connect(
      onLocalSignal: (
        WebrtcSignalType signalType, {
        String? sdp,
        Map<String, dynamic>? candidate,
      }) {
        AppLogger.trace(
          'send mobile webrtc signal sessionId=$sessionId signalType=${signalType.apiValue}',
        );
        return _apiClient.sendMobileWebrtcSignal(
          accessToken: accessToken,
          sessionId: sessionId,
          signalType: signalType,
          sdp: sdp,
          candidate: candidate,
        );
      },
    );
    _bindEventStream(accessToken: accessToken);
    await loadSnapshots(accessToken: accessToken);
    _startSnapshotRefreshTimer(accessToken);
    if (initialState != 'pending_approval') {
      await _sendInitialOffer(accessToken);
    }

    state = state.copyWith(loading: false, clearError: true);
  }

  Future<void> loadSnapshots({required String accessToken}) async {
    final deviceId = state.deviceId;
    if (deviceId == null) {
      return;
    }

    try {
      final snapshots = await _apiClient.listSnapshots(
        accessToken: accessToken,
        deviceId: deviceId,
      );
      state = state.copyWith(
        snapshots: snapshots,
        selectedScreenId: state.selectedScreenId ??
            (snapshots.isEmpty ? null : snapshots.first.screenId),
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(errorMessage: '加载屏幕快照失败: $error');
    }
  }

  Future<void> selectScreen({
    required String accessToken,
    required String screenId,
  }) async {
    final sessionId = state.sessionId;
    if (sessionId == null) {
      return;
    }

    try {
      await _apiClient.switchScreen(
        accessToken: accessToken,
        sessionId: sessionId,
        screenId: screenId,
      );
      state = state.copyWith(selectedScreenId: screenId, clearError: true);
    } catch (error) {
      state = state.copyWith(errorMessage: '切换屏幕失败: $error');
    }
  }

  Future<void> setManualQuality({
    required String accessToken,
    required QualityProfile profile,
  }) async {
    final sessionId = state.sessionId;
    if (sessionId == null) {
      return;
    }

    await _streamController.setQualityProfile(profile);

    try {
      await _apiClient.updateSessionQuality(
        accessToken: accessToken,
        sessionId: sessionId,
        autoMode: false,
        profile: _qualityProfileToApi(profile),
      );
      state = state.copyWith(
        autoQuality: false,
        qualityProfile: profile,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(errorMessage: '更新分辨率失败: $error');
    }
  }

  Future<void> setAutoQuality({required String accessToken}) async {
    final sessionId = state.sessionId;
    if (sessionId == null) {
      return;
    }

    await _streamController.setAutoQuality(true);

    try {
      await _apiClient.updateSessionQuality(
        accessToken: accessToken,
        sessionId: sessionId,
        autoMode: true,
      );
      state = state.copyWith(autoQuality: true, clearError: true);
    } catch (error) {
      state = state.copyWith(errorMessage: '切换自动码率失败: $error');
    }
  }

  Future<void> setSnapshotRefreshSeconds({
    required int seconds,
  }) async {
    final next = seconds.clamp(2, 30);
    state = state.copyWith(snapshotRefreshSeconds: next);

    final accessToken = _boundAccessToken;
    if (accessToken != null) {
      _startSnapshotRefreshTimer(accessToken);
    }
  }

  Future<void> rotate(ViewOrientationMode mode) async {
    state = state.copyWith(orientationMode: mode);
    if (mode == ViewOrientationMode.landscape) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      return;
    }

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  Future<void> onAppBackground({
    required String accessToken,
  }) async {
    final sessionId = state.sessionId;
    if (sessionId == null) {
      return;
    }

    try {
      await _apiClient.pauseSession(accessToken: accessToken, sessionId: sessionId);
    } catch (error) {
      state = state.copyWith(errorMessage: '暂停会话失败: $error');
      return;
    }

    final deadline = DateTime.now().add(const Duration(minutes: 3));
    state = state.copyWith(
      backgroundPauseDeadline: deadline,
      sessionState: 'paused',
      clearError: true,
    );

    _backgroundTimer?.cancel();
    _backgroundTimer = Timer(const Duration(minutes: 3), () {
      unawaited(() async {
        try {
          await _apiClient.terminateSession(accessToken: accessToken, sessionId: sessionId);
        } catch (_) {}
        await _handleRemoteSessionEnded(lastEventType: 'session.auto_terminated');
      }());
    });
  }

  Future<void> onAppForeground({
    required String accessToken,
  }) async {
    final sessionId = state.sessionId;
    if (sessionId == null) {
      return;
    }

    _backgroundTimer?.cancel();
    try {
      await _apiClient.resumeSession(accessToken: accessToken, sessionId: sessionId);
      state = state.copyWith(
        backgroundPauseDeadline: null,
        sessionState: 'streaming',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(errorMessage: '恢复会话失败: $error');
    }
  }

  Future<void> disconnect({
    required String accessToken,
  }) async {
    final sessionId = state.sessionId;
    if (sessionId != null) {
      try {
        await _apiClient.terminateSession(accessToken: accessToken, sessionId: sessionId);
      } catch (_) {}
    }

    await _stopRuntimeResources();
    await rotate(ViewOrientationMode.portrait);
    _clearSessionViewState();
  }

  void _bindEventStream({required String accessToken}) {
    final eventClient = _eventClient;
    if (eventClient == null) {
      return;
    }

    _eventSubscription?.cancel();
    _eventChannel?.sink.close();

    final channel = eventClient.connectMobileEvents(accessToken: accessToken);
    _eventChannel = channel;
    _eventSubscription = channel.stream.listen(
      (event) {
        final decoded = BackendEventClient.decodeEvent(event);
        if (decoded == null) {
          return;
        }

        final eventType = decoded['type'] as String?;
        final payload = decoded['payload'];
        state = state.copyWith(lastEventType: eventType);

        if (eventType == null) {
          return;
        }

        AppLogger.info(
          '$_mediaStreamTraceTag mobile event received type=$eventType sessionId=${state.sessionId ?? '-'}',
        );

        switch (eventType) {
          case 'connection.request.accepted':
            unawaited(_applyConnectionAccepted(payload));
            break;
          case 'connection.request.rejected':
            unawaited(_applyConnectionRejected(payload));
            break;
          case 'session.state.changed':
            unawaited(_applySessionStateChanged(payload));
            break;
          case 'session.auto_terminated':
            unawaited(
              _handleRemoteSessionEnded(
                lastEventType: 'session.auto_terminated',
              ),
            );
            break;
          case 'webrtc.offer':
            _handleRemoteOffer(payload);
            break;
          case 'webrtc.answer':
            _handleRemoteAnswer(payload);
            break;
          case 'webrtc.ice_candidate':
            _handleRemoteCandidate(payload);
            break;
          default:
            break;
        }
      },
      onError: (error) {
        AppLogger.error('mobile event channel error: $error');
        state = state.copyWith(errorMessage: '事件通道异常: $error');
      },
    );
  }

  Future<void> _sendInitialOffer(String accessToken) async {
    final sessionId = state.sessionId;
    if (sessionId == null || _initialOfferSent) {
      return;
    }

    try {
      final offer = await _streamController.createOffer();
      await _apiClient.sendMobileWebrtcSignal(
        accessToken: accessToken,
        sessionId: sessionId,
        signalType: WebrtcSignalType.offer,
        sdp: offer,
      );
      _initialOfferSent = true;
      AppLogger.info(
        '$_mediaStreamTraceTag mobile initial offer sent sessionId=$sessionId length=${offer.length}',
      );
      AppLogger.info('initial mobile offer sent sessionId=$sessionId');
    } catch (error) {
      AppLogger.error('initial mobile offer failed sessionId=$sessionId error=$error');
      state = state.copyWith(errorMessage: '初始化 WebRTC 失败: $error');
    }
  }

  Future<void> _applyConnectionAccepted(dynamic payload) async {
    final payloadMap = _mapPayload(payload);
    if (!_isCurrentSession(payloadMap)) {
      return;
    }

    state = state.copyWith(
      sessionState: (payloadMap['state'] as String?) ?? 'connecting',
      clearError: true,
    );
    AppLogger.info('connection accepted sessionId=${state.sessionId}');

    final accessToken = _boundAccessToken;
    if (accessToken != null) {
      await _sendInitialOffer(accessToken);
    }
  }

  Future<void> _applyConnectionRejected(dynamic payload) async {
    final payloadMap = _mapPayload(payload);
    if (!_isCurrentSession(payloadMap)) {
      return;
    }

    final reason = payloadMap['reason'] as String? ?? 'desktop rejected';
    AppLogger.warn('connection rejected sessionId=${state.sessionId} reason=$reason');
    await _handleRemoteSessionEnded(
      errorMessage: '连接被拒绝: $reason',
      lastEventType: 'connection.request.rejected',
    );
  }

  Future<void> _applySessionStateChanged(dynamic payload) async {
    final payloadMap = _mapPayload(payload);
    if (!_isCurrentSession(payloadMap)) {
      return;
    }

    final nextState = payloadMap['state'] as String?;
    final screenId = payloadMap['screen_id'] as String?;
    final qualityMode = payloadMap['quality_mode'] as String?;
    final qualityProfileRaw = payloadMap['quality_profile'] as String?;

    state = state.copyWith(
      sessionState: nextState,
      selectedScreenId: screenId ?? state.selectedScreenId,
      autoQuality: qualityMode == null ? state.autoQuality : qualityMode != 'manual',
      qualityProfile: _qualityProfileFromApi(qualityProfileRaw) ?? state.qualityProfile,
    );
    AppLogger.info(
      'session state changed sessionId=${state.sessionId} nextState=${nextState ?? 'unknown'}',
    );

    if (nextState == 'terminated') {
      await _handleRemoteSessionEnded(
        lastEventType: 'session.state.changed',
      );
    }
  }

  Future<void> _handleRemoteOffer(dynamic payload) async {
    final payloadMap = _mapPayload(payload);
    if (!_isCurrentSession(payloadMap)) {
      return;
    }

    final sdp = payloadMap['sdp'] as String?;
    final accessToken = _boundAccessToken;
    final sessionId = state.sessionId;
    if (sdp == null || accessToken == null || sessionId == null) {
      return;
    }

    try {
      final answer = await _streamController.createAnswerForOffer(sdp);
      await _apiClient.sendMobileWebrtcSignal(
        accessToken: accessToken,
        sessionId: sessionId,
        signalType: WebrtcSignalType.answer,
        sdp: answer,
      );
      AppLogger.info(
        '$_mediaStreamTraceTag mobile answer sent sessionId=$sessionId length=${answer.length}',
      );
      AppLogger.info('mobile handled remote offer sessionId=$sessionId');
    } catch (error) {
      AppLogger.error('handle remote offer failed sessionId=$sessionId error=$error');
      state = state.copyWith(errorMessage: '处理远端 Offer 失败: $error');
    }
  }

  Future<void> _handleRemoteAnswer(dynamic payload) async {
    final payloadMap = _mapPayload(payload);
    if (!_isCurrentSession(payloadMap)) {
      return;
    }

    final sdp = payloadMap['sdp'] as String?;
    if (sdp == null) {
      return;
    }

    await _streamController.applyRemoteAnswer(sdp);
    AppLogger.info(
      '$_mediaStreamTraceTag mobile remote answer applied sessionId=${state.sessionId} length=${sdp.length}',
    );
    state = state.copyWith(sessionState: 'streaming', clearError: true);
    AppLogger.info('mobile applied remote answer sessionId=${state.sessionId}');
  }

  Future<void> _handleRemoteCandidate(dynamic payload) async {
    final payloadMap = _mapPayload(payload);
    if (!_isCurrentSession(payloadMap)) {
      return;
    }

    final candidate = payloadMap['candidate'];
    if (candidate is Map) {
      await _streamController.addRemoteCandidate(
        candidate.map(
          (key, value) => MapEntry(key.toString(), value),
        ),
      );
      AppLogger.trace('mobile applied remote candidate sessionId=${state.sessionId}');
    }
  }

  Map<String, dynamic> _mapPayload(dynamic payload) {
    if (payload is Map<String, dynamic>) {
      return payload;
    }
    return const <String, dynamic>{};
  }

  bool _isCurrentSession(Map<String, dynamic> payload) {
    final currentSessionId = state.sessionId;
    if (currentSessionId == null) {
      return false;
    }

    final eventSessionId = payload['session_id'] as String?;
    return eventSessionId == currentSessionId;
  }

  void _startSnapshotRefreshTimer(String accessToken) {
    _snapshotRefreshTimer?.cancel();
    final interval = Duration(seconds: state.snapshotRefreshSeconds);
    _snapshotRefreshTimer = Timer.periodic(interval, (_) {
      loadSnapshots(accessToken: accessToken);
    });
  }

  Future<void> _stopRuntimeResources() async {
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    _snapshotRefreshTimer?.cancel();
    _snapshotRefreshTimer = null;

    await _streamController.disconnect();
    await _eventSubscription?.cancel();
    _eventChannel?.sink.close();
    _eventSubscription = null;
    _eventChannel = null;
  }

  Future<void> _handleRemoteSessionEnded({
    String? errorMessage,
    String? lastEventType,
  }) async {
    await _stopRuntimeResources();
    await rotate(ViewOrientationMode.portrait);
    _clearSessionViewState();
    state = state.copyWith(
      lastEventType: lastEventType,
      errorMessage: errorMessage,
      clearError: errorMessage == null,
    );
  }

  void _clearSessionViewState() {
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    _snapshotRefreshTimer?.cancel();
    _snapshotRefreshTimer = null;
    _initialOfferSent = false;

    state = state.copyWith(
      sessionId: null,
      deviceId: null,
      sessionState: null,
      loading: false,
      backgroundPauseDeadline: null,
      orientationMode: ViewOrientationMode.portrait,
      snapshots: const [],
      selectedScreenId: null,
    );
  }

  QualityProfile? _qualityProfileFromApi(String? profile) {
    switch (profile) {
      case 'p480':
        return QualityProfile.p480;
      case 'p1080':
        return QualityProfile.p1080;
      case 'p720':
        return QualityProfile.p720;
      default:
        return null;
    }
  }

  String _qualityProfileToApi(QualityProfile profile) {
    switch (profile) {
      case QualityProfile.p480:
        return 'p480';
      case QualityProfile.p720:
        return 'p720';
      case QualityProfile.p1080:
        return 'p1080';
    }
  }

  @override
  void dispose() {
    unawaited(_stopRuntimeResources());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }
}

final remoteViewViewModelProvider =
    StateNotifierProvider<RemoteViewViewModel, RemoteViewState>((ref) {
  final apiClient = ref.watch(backendApiClientProvider);
  final eventClient = ref.watch(backendEventClientProvider);
  final streamController = ref.watch(remoteStreamControllerProvider.notifier);
  return RemoteViewViewModel(
    apiClient: apiClient,
    eventClient: eventClient,
    streamController: streamController,
  );
});
