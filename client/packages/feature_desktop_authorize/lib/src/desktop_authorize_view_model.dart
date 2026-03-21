import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

import 'desktop_authorize_state.dart';

const _authMediaTraceTag = '[MEDIA_AUTH_TRACE]';

class DesktopAuthorizeViewModel extends BaseViewModel<DesktopAuthorizeState> {
  DesktopAuthorizeViewModel(this._localClient, this._apiClient, this._mediaController)
      : super(const DesktopAuthorizeState());

  final DesktopLocalClient _localClient;
  final BackendApiClient _apiClient;
  final DesktopMediaController _mediaController;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  AuthSession? _authSession;
  bool _syncingRegistration = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _closingChannel = false;
  bool _disposed = false;

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
      await _syncDeviceRegistration();
    } catch (error) {
      AppLogger.error('connect desktop local websocket failed: $error');
      state = state.copyWith(
        connecting: false,
        connected: false,
        errorMessage: '连接 desktop-server 失败: $error',
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
      state = state.copyWith(errorMessage: '本地连接已断开，无法提交授权');
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
          errorMessage: '本地连接异常: $error',
        );
        if (!_closingChannel) {
          _scheduleReconnect();
        }
      },
      onDone: () {
        AppLogger.warn('desktop local websocket disconnected');
        state = state.copyWith(connected: false);
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
      case 'session.control.terminate':
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
      state = state.copyWith(clearError: true);
    } catch (error) {
      AppLogger.error('desktop media start answering failed: $error');
      state = state.copyWith(errorMessage: '启动屏幕共享失败: $error');
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
      state = state.copyWith(errorMessage: '应用远端候选失败: $error');
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
        platform: 'desktop',
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
        errorMessage: '设备注册失败: $error',
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
      state = state.copyWith(errorMessage: '同步自动授权设置失败: $error');
    }
  }

  String _buildDeviceName(String deviceId) {
    final suffix = deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;
    return 'Desktop-$suffix';
  }

  Future<void> _closeChannel() async {
    _closingChannel = true;
    _cancelReconnect();
    AppLogger.info('closing desktop local websocket');
    await _mediaController.stop();
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _closingChannel = false;
    state = state.copyWith(connected: false, connecting: false);
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

  @override
  void dispose() {
    _disposed = true;
    _cancelReconnect();
    unawaited(_closeChannel());
    super.dispose();
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
  final viewModel = DesktopAuthorizeViewModel(localClient, apiClient, mediaController);
  ref.listen(desktopMediaControllerProvider, (_, next) {
    viewModel.syncMediaState(next);
  });
  return viewModel;
});
