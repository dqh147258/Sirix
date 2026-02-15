import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'desktop_authorize_state.dart';

class DesktopAuthorizeViewModel extends BaseViewModel<DesktopAuthorizeState> {
  DesktopAuthorizeViewModel(this._localClient) : super(const DesktopAuthorizeState());

  final DesktopLocalClient _localClient;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  Future<void> connect() async {
    if (state.connected || state.connecting) {
      return;
    }

    state = state.copyWith(connecting: true, clearError: true);
    try {
      final channel = await _localClient.connect();
      _channel = channel;
      _bindChannel(channel);
      state = state.copyWith(connecting: false, connected: true, clearError: true);
    } catch (error) {
      state = state.copyWith(
        connecting: false,
        connected: false,
        errorMessage: '连接 desktop-server 失败: $error',
      );
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
      AppLogger.info('approve session: $sessionId');
      return;
    }

    AppLogger.warn('reject session: $sessionId');
  }

  void _bindChannel(WebSocketChannel channel) {
    _subscription?.cancel();
    _subscription = channel.stream.listen(
      _handleLocalEvent,
      onError: (error) {
        state = state.copyWith(
          connected: false,
          errorMessage: '本地连接异常: $error',
        );
      },
      onDone: () {
        state = state.copyWith(connected: false);
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
        state = state.copyWith(autoApprove: autoApprove, clearError: true);
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
          return;
        }

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
        state = state.copyWith(
          pendingRequests: state.pendingRequests
              .where((request) => request.sessionId != sessionId)
              .toList(growable: false),
        );
        break;
      default:
        break;
    }
  }

  Future<void> _closeChannel() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    state = state.copyWith(connected: false, connecting: false);
  }

  @override
  void dispose() {
    unawaited(_closeChannel());
    super.dispose();
  }
}

final desktopAuthorizeViewModelProvider =
    StateNotifierProvider<DesktopAuthorizeViewModel, DesktopAuthorizeState>((ref) {
  final localClient = ref.watch(desktopLocalClientProvider);
  return DesktopAuthorizeViewModel(localClient);
});
