import 'dart:async';
import 'dart:io' show Platform;
import 'package:uuid/uuid.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

import 'desktop_terminal_channel_bridge.dart';
import 'desktop_authorize_state.dart';

const _authMediaTraceTag = '[MEDIA_AUTH_TRACE]';
const Duration _latencyProbeTimeout = Duration(seconds: 3);
const _remoteConnectTraceTag = '[REMOTE_CONNECT_TRACE]';

class DesktopAuthorizeViewModel extends BaseViewModel<DesktopAuthorizeState> {
  DesktopAuthorizeViewModel(
    this._localClient,
    this._apiClient,
    this._mediaController,
    this._terminalBridge,
  ) : super(const DesktopAuthorizeState());

  final DesktopLocalClient _localClient;
  final BackendApiClient _apiClient;
  final DesktopMediaController _mediaController;
  final DesktopTerminalChannelBridge _terminalBridge;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  AuthSession? _authSession;
  bool _syncingRegistration = false;
  Timer? _reconnectTimer;
  Timer? _latencyProbeTimer;
  int _reconnectAttempt = 0;
  bool _closingChannel = false;
  bool _disposed = false;
  DateTime? _lastPingSentAt;
  String? _lastPingRequestId;

  Future<void> bindAuthSession(AuthSession? session) async {
    _authSession = session;
    if (session == null) {
      state = state.copyWith(
        registeredDeviceId: null,
      );
      return;
    }

    await _syncDeviceRegistration();
  }

  Future<void> connect() async {
    if (_disposed || state.connected || state.connecting) {
      return;
    }

    _cancelReconnect();
    state = state.copyWith(connecting: true, clearError: true);
    try {
      AppLogger.info('connecting desktop local websocket');
      final channel = await _localClient.connect();
      _channel = channel;
      _bindChannel(channel);
      _reconnectAttempt = 0;
      state = state.copyWith(connecting: false, connected: true, clearError: true);
      AppLogger.info('desktop local websocket connected');
      _startLatencyProbe();
      // 远控首连时 desktop 侧的 WebRTC 工厂惰性初始化会明显放大 offer->answer
      // 时延，因此在本地 WS 已连上、桌面端空闲时就后台预热一次。
      unawaited(_warmUpDesktopRtc());
      await _syncDeviceRegistration();
    } catch (error) {
      AppLogger.error('connect desktop local websocket failed: $error');
      state = state.copyWith(
        connecting: false,
        connected: false,
        localLatencyMs: null,
        errorMessage: AppLocalizations.current.connectDesktopFailed('$error'),
      );
      _scheduleReconnect();
    }
  }

  Future<void> reconnect() async {
    await _closeChannel();
    await connect();
  }

  void setAutoApprove(bool value) {
    state = state.copyWith(autoApprove: value, clearError: true);

    final channel = _channel;
    if (channel != null) {
      _localClient.sendSetAutoApprove(
        channel: channel,
        autoApprove: value,
      );
    }

    unawaited(_syncAutoApproveToBackend(value));
  }

  void approve(String sessionId) {
    _sendAuthorize(sessionId: sessionId, approve: true);
  }

  void reject(String sessionId) {
    _sendAuthorize(sessionId: sessionId, approve: false);
  }

  void _sendAuthorize({
    required String sessionId,
    required bool approve,
  }) {
    final channel = _channel;
    if (channel == null) {
      state = state.copyWith(errorMessage: AppLocalizations.current.localConnectionUnavailable);
      return;
    }

    _localClient.sendAuthorizeResponse(
      channel: channel,
      sessionId: sessionId,
      approve: approve,
    );

    state = state.copyWith(
      pendingRequests: state.pendingRequests
          .where((request) => request.sessionId != sessionId)
          .toList(growable: false),
      clearError: true,
    );

    if (approve) {
      AppLogger.info('$_authMediaTraceTag approve tapped sessionId=$sessionId');
      AppLogger.info('approve session: $sessionId');
      return;
    }

    AppLogger.warn('$_authMediaTraceTag reject tapped sessionId=$sessionId');
    AppLogger.warn('reject session: $sessionId');
  }

  void _bindChannel(WebSocketChannel channel) {
    _subscription?.cancel();
    _subscription = channel.stream.listen(
      _handleLocalEvent,
      onError: (error) {
        AppLogger.error('desktop local websocket error: $error');
        state = state.copyWith(
          connected: false,
          localLatencyMs: null,
          errorMessage: AppLocalizations.current.localConnectionError('$error'),
        );
        _stopLatencyProbe();
        if (!_closingChannel) {
          _scheduleReconnect();
        }
      },
      onDone: () {
        AppLogger.warn('desktop local websocket disconnected');
        state = state.copyWith(connected: false, localLatencyMs: null);
        _stopLatencyProbe();
        if (!_closingChannel) {
          _scheduleReconnect();
        }
      },
    );
  }

  void _handleLocalEvent(dynamic event) {
    final decoded = DesktopLocalClient.decodeEvent(event);
    if (decoded == null) {
      return;
    }

    final type = decoded['type'] as String?;
    if (type == null) {
      return;
    }

    state = state.copyWith(lastEventType: type);

    switch (type) {
      case 'settings.sync':
        final autoApprove = decoded['auto_approve_screen_share'] as bool? ?? false;
        final deviceId = decoded['device_id'] as String?;
        final localWsPort = decoded['local_ws_port'] as int?;
        final loggingEnabled = decoded['logging_enabled'] as bool?;
        if (loggingEnabled != null) {
          AppLogger.setEnabled(loggingEnabled);
        }
        AppLogger.info(
          'received settings.sync deviceId=${deviceId ?? '-'} localWsPort=${localWsPort ?? '-'} autoApprove=$autoApprove loggingEnabled=${loggingEnabled ?? 'unknown'}',
        );
        state = state.copyWith(
          autoApprove: autoApprove,
          deviceId: deviceId,
          localWsPort: localWsPort,
          clearError: true,
        );
        unawaited(_syncDeviceRegistration());
        break;
      case 'pong':
        final requestId = decoded['request_id'] as String?;
        final sentAt = _lastPingSentAt;
        if (sentAt != null &&
            (_lastPingRequestId == null ||
                requestId == null ||
                requestId == _lastPingRequestId)) {
          final latencyMs = DateTime.now().difference(sentAt).inMilliseconds.clamp(0, 9999);
          state = state.copyWith(localLatencyMs: latencyMs);
          _lastPingSentAt = null;
          _lastPingRequestId = null;
        }
        break;
      case 'authorize.request':
        final sessionId = decoded['session_id'] as String?;
        if (sessionId == null || sessionId.isEmpty) {
          return;
        }

        final requesterRaw = decoded['requester'];
        final requester = requesterRaw is String ? requesterRaw : 'mobile-user';
        final targetRaw = decoded['target_device_id'];
        final deviceName = targetRaw is String ? targetRaw : 'desktop-device';
        final exists = state.pendingRequests.any((request) => request.sessionId == sessionId);
        if (exists) {
          AppLogger.warn('duplicate authorize request ignored: $sessionId');
          return;
        }

        AppLogger.info(
          '$_authMediaTraceTag received authorize.request sessionId=$sessionId requester=$requester',
        );
        AppLogger.info('received authorize.request sessionId=$sessionId requester=$requester');
        state = state.copyWith(
          pendingRequests: [
            ...state.pendingRequests,
            PendingAuthorizeRequest(
              sessionId: sessionId,
              requester: requester,
              deviceName: deviceName,
            ),
          ],
          clearError: true,
        );
        break;
      case 'authorize.ack':
        final sessionId = decoded['session_id'] as String?;
        if (sessionId == null) {
          return;
        }
        AppLogger.info('$_authMediaTraceTag received authorize.ack sessionId=$sessionId');
        AppLogger.info('received authorize.ack sessionId=$sessionId');
        state = state.copyWith(
          pendingRequests: state.pendingRequests
              .where((request) => request.sessionId != sessionId)
              .toList(growable: false),
        );
        break;
      case 'webrtc.offer':
        unawaited(_handleDesktopOffer(decoded));
        break;
      case 'webrtc.ice_candidate':
        unawaited(_applyRemoteCandidate(decoded));
        break;
      case 'session.control.switch_screen':
        unawaited(_handleScreenSwitch(decoded));
        break;
      case 'session.control.quality_changed':
        unawaited(_handleQualityChanged(decoded));
        break;
      case 'session.control.terminate':
        unawaited(_terminalBridge.unbindSession());
        unawaited(_mediaController.stop());
        break;
      default:
        break;
    }
  }

  Future<void> _handleDesktopOffer(Map<String, dynamic> event) async {
    final payload = event['payload'];
    if (payload is! Map<String, dynamic>) {
      return;
    }

    final sessionId = payload['session_id'] as String?;
    final sdp = payload['sdp'] as String?;
    final channel = _channel;
    if (sessionId == null || sessionId.isEmpty || sdp == null || channel == null) {
      return;
    }

    try {
      AppLogger.info(
        '$_remoteConnectTraceTag sessionId=$sessionId stage=desktop_offer_received sdp_length=${sdp.length}',
      );
      await _mediaController.startAnswering(
        sessionId: sessionId,
        remoteOfferSdp: sdp,
        onLocalSignal: (signalType, {sdp, candidate}) async {
          _localClient.sendWebrtcSignal(
            channel: channel,
            sessionId: sessionId,
            signalType: signalType,
            sdp: sdp,
            candidate: candidate,
          );
        },
      );
      AppLogger.info(
        '$_remoteConnectTraceTag sessionId=$sessionId stage=desktop_answer_ready',
      );
      await _terminalBridge.bindSession(sessionId);
      state = state.copyWith(clearError: true);
    } catch (error) {
      AppLogger.error('desktop media start answering failed: $error');
      state = state.copyWith(
        errorMessage: AppLocalizations.current.startScreenShareFailed('$error'),
      );
    }
  }

  Future<void> _applyRemoteCandidate(Map<String, dynamic> event) async {
    final payload = event['payload'];
    if (payload is! Map) {
      return;
    }

    final candidate = payload['candidate'];
    if (candidate is! Map) {
      return;
    }

    try {
      await _mediaController.addRemoteCandidate(
        candidate.map((key, value) => MapEntry(key.toString(), value)),
      );
      AppLogger.trace('desktop remote candidate applied');
    } catch (error) {
      AppLogger.error('apply remote candidate failed: $error');
      state = state.copyWith(
        errorMessage: AppLocalizations.current.applyRemoteCandidateFailed('$error'),
      );
    }
  }

  Future<void> _handleScreenSwitch(Map<String, dynamic> event) async {
    final payload = event['payload'];
    if (payload is! Map<String, dynamic>) {
      return;
    }

    final sessionId = payload['session_id'] as String?;
    final screenId = payload['screen_id'] as String?;
    if (sessionId == null || sessionId.isEmpty || screenId == null || screenId.isEmpty) {
      return;
    }

    try {
      AppLogger.info(
        '$_authMediaTraceTag desktop received switch_screen sessionId=$sessionId screenId=$screenId',
      );
      await _mediaController.switchSharedScreen(
        sessionId: sessionId,
        screenId: screenId,
      );
      state = state.copyWith(clearError: true);
    } catch (error) {
      AppLogger.error('desktop switch shared screen failed: $error');
      state = state.copyWith(
        errorMessage: AppLocalizations.current.switchSharedScreenFailed('$error'),
      );
    }
  }

  Future<void> _handleQualityChanged(Map<String, dynamic> event) async {
    final payload = event['payload'];
    if (payload is! Map<String, dynamic>) {
      return;
    }

    final sessionId = payload['session_id'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return;
    }

    final profile = _qualityProfileFromApi(payload['quality_profile'] as String?);

    try {
      await _mediaController.setPreferredQualityProfile(
        sessionId: sessionId,
        profile: profile,
      );
      state = state.copyWith(clearError: true);
    } catch (error) {
      AppLogger.error('desktop update capture profile failed: $error');
      state = state.copyWith(
        errorMessage: AppLocalizations.current.switchSharedScreenFailed('$error'),
      );
    }
  }

  Future<void> _syncDeviceRegistration() async {
    final authSession = _authSession;
    final deviceId = state.deviceId;

    if (authSession == null || deviceId == null || deviceId.isEmpty) {
      return;
    }

    if (_syncingRegistration) {
      return;
    }

    _syncingRegistration = true;
    state = state.copyWith(registeringDevice: true, clearError: true);

    try {
      final registered = await _apiClient.registerDevice(
        accessToken: authSession.accessToken,
        deviceName: _buildDeviceName(deviceId),
        platform: _desktopPlatform(),
        clientVersion: '0.1.0',
        preferredDeviceId: deviceId,
      );

      state = state.copyWith(
        registeredDeviceId: registered.id,
        registeringDevice: false,
        clearError: true,
      );
      AppLogger.info('desktop device registered id=${registered.id}');

      if (registered.autoApproveScreenShare != state.autoApprove) {
        final channel = _channel;
        if (channel != null) {
          _localClient.sendSetAutoApprove(
            channel: channel,
            autoApprove: registered.autoApproveScreenShare,
          );
        }
        state = state.copyWith(autoApprove: registered.autoApproveScreenShare, clearError: true);
      }
    } catch (error) {
      AppLogger.error('desktop device registration failed: $error');
      state = state.copyWith(
        registeringDevice: false,
        errorMessage: AppLocalizations.current.deviceRegistrationFailed('$error'),
      );
    } finally {
      _syncingRegistration = false;
    }
  }

  Future<void> _syncAutoApproveToBackend(bool autoApprove) async {
    final authSession = _authSession;
    if (authSession == null) {
      return;
    }

    var deviceId = state.registeredDeviceId ?? state.deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      await _syncDeviceRegistration();
      deviceId = state.registeredDeviceId ?? state.deviceId;
    }

    if (deviceId == null || deviceId.isEmpty) {
      return;
    }

    try {
      final updated = await _apiClient.updateDeviceAutoApprove(
        accessToken: authSession.accessToken,
        deviceId: deviceId,
        autoApprove: autoApprove,
      );
      state = state.copyWith(
        registeredDeviceId: updated.id,
        autoApprove: updated.autoApproveScreenShare,
        clearError: true,
      );
      AppLogger.info('desktop auto approve synced value=${updated.autoApproveScreenShare}');
    } catch (error) {
      AppLogger.error('sync auto approve to backend failed: $error');
      state = state.copyWith(
        errorMessage: AppLocalizations.current.syncAutoApproveFailed('$error'),
      );
    }
  }

  String _buildDeviceName(String deviceId) {
    final suffix = deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;
    return '${_desktopPlatformLabel()} Desktop-$suffix';
  }

  String _desktopPlatform() {
    if (Platform.isLinux) {
      return 'linux';
    }
    if (Platform.isMacOS) {
      return 'macos';
    }
    if (Platform.isWindows) {
      return 'windows';
    }
    return 'desktop';
  }

  String _desktopPlatformLabel() {
    final platform = _desktopPlatform();
    return platform[0].toUpperCase() + platform.substring(1);
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

  Future<void> _closeChannel() async {
    _closingChannel = true;
    _cancelReconnect();
    _stopLatencyProbe();
    AppLogger.info('closing desktop local websocket');
    await _terminalBridge.unbindSession();
    await _mediaController.stop();
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _closingChannel = false;
    state = state.copyWith(connected: false, connecting: false, localLatencyMs: null);
  }

  void _scheduleReconnect() {
    if (_disposed || state.connected || state.connecting || (_reconnectTimer?.isActive ?? false)) {
      return;
    }

    _reconnectAttempt = (_reconnectAttempt + 1).clamp(1, 5);
    _reconnectTimer = Timer(Duration(seconds: _reconnectAttempt), () {
      _reconnectTimer = null;
      unawaited(connect());
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  Future<void> _warmUpDesktopRtc() async {
    try {
      await _mediaController.warmUpRtc();
    } catch (error) {
      AppLogger.warn('desktop rtc warmup skipped error=$error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelReconnect();
    _stopLatencyProbe();
    unawaited(_closeChannel());
    unawaited(_terminalBridge.dispose());
    super.dispose();
  }

  void _startLatencyProbe() {
    _stopLatencyProbe();
    _sendLatencyProbe();
    _latencyProbeTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _sendLatencyProbe(),
    );
  }

  void _stopLatencyProbe() {
    _latencyProbeTimer?.cancel();
    _latencyProbeTimer = null;
    _lastPingSentAt = null;
    _lastPingRequestId = null;
  }

  void _sendLatencyProbe() {
    final channel = _channel;
    if (_disposed || channel == null || !state.connected) {
      return;
    }

    final lastPingSentAt = _lastPingSentAt;
    if (lastPingSentAt != null) {
      if (DateTime.now().difference(lastPingSentAt) < _latencyProbeTimeout) {
        return;
      }
      _lastPingSentAt = null;
      _lastPingRequestId = null;
      state = state.copyWith(localLatencyMs: null);
    }

    final requestId = const Uuid().v4();
    _lastPingSentAt = DateTime.now();
    _lastPingRequestId = requestId;
    _localClient.sendPing(channel: channel, requestId: requestId);
  }

  void syncMediaState(DesktopMediaState mediaState) {
    state = state.copyWith(
      mediaInitializing: mediaState.initializing,
      mediaSharing: mediaState.sharing,
    );
  }
}

final desktopAuthorizeViewModelProvider =
    StateNotifierProvider<DesktopAuthorizeViewModel, DesktopAuthorizeState>((ref) {
  final localClient = ref.watch(desktopLocalClientProvider);
  final apiClient = ref.watch(backendApiClientProvider);
  final mediaController = ref.watch(desktopMediaControllerProvider.notifier);
  final terminalChannelController = ref.watch(
    sessionTerminalChannelControllerProvider.notifier,
  );
  final terminalBridge = DesktopTerminalChannelBridge(
    localClient: localClient,
    terminalChannelController: terminalChannelController,
  );
  final viewModel = DesktopAuthorizeViewModel(
    localClient,
    apiClient,
    mediaController,
    terminalBridge,
  );
  ref.listen(desktopMediaControllerProvider, (_, next) {
    viewModel.syncMediaState(next);
  });
  return viewModel;
});
