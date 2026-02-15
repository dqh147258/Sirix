import 'package:flutter/foundation.dart';

@immutable
class PendingAuthorizeRequest {
  const PendingAuthorizeRequest({
    required this.sessionId,
    required this.requester,
    required this.deviceName,
  });

  final String sessionId;
  final String requester;
  final String deviceName;
}

@immutable
class DesktopAuthorizeState {
  const DesktopAuthorizeState({
    this.connecting = false,
    this.connected = false,
    this.autoApprove = false,
    this.pendingRequests = const [],
    this.lastEventType,
    this.errorMessage,
  });

  final bool connecting;
  final bool connected;
  final bool autoApprove;
  final List<PendingAuthorizeRequest> pendingRequests;
  final String? lastEventType;
  final String? errorMessage;

  DesktopAuthorizeState copyWith({
    bool? connecting,
    bool? connected,
    bool? autoApprove,
    List<PendingAuthorizeRequest>? pendingRequests,
    String? lastEventType,
    String? errorMessage,
    bool clearError = false,
  }) {
    return DesktopAuthorizeState(
      connecting: connecting ?? this.connecting,
      connected: connected ?? this.connected,
      autoApprove: autoApprove ?? this.autoApprove,
      pendingRequests: pendingRequests ?? this.pendingRequests,
      lastEventType: lastEventType ?? this.lastEventType,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
