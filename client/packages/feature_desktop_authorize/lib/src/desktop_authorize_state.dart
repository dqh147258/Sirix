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
    this.mediaInitializing = false,
    this.mediaSharing = false,
    this.pendingRequests = const [],
    this.lastEventType,
    this.deviceId,
    this.localWsPort,
    this.registeredDeviceId,
    this.registeringDevice = false,
    this.errorMessage,
  });

  static const _unset = Object();

  final bool connecting;
  final bool connected;
  final bool autoApprove;
  final bool mediaInitializing;
  final bool mediaSharing;
  final List<PendingAuthorizeRequest> pendingRequests;
  final String? lastEventType;
  final String? deviceId;
  final int? localWsPort;
  final String? registeredDeviceId;
  final bool registeringDevice;
  final String? errorMessage;

  DesktopAuthorizeState copyWith({
    bool? connecting,
    bool? connected,
    bool? autoApprove,
    bool? mediaInitializing,
    bool? mediaSharing,
    List<PendingAuthorizeRequest>? pendingRequests,
    String? lastEventType,
    Object? deviceId = _unset,
    int? localWsPort,
    Object? registeredDeviceId = _unset,
    bool? registeringDevice,
    String? errorMessage,
    bool clearError = false,
  }) {
    return DesktopAuthorizeState(
      connecting: connecting ?? this.connecting,
      connected: connected ?? this.connected,
      autoApprove: autoApprove ?? this.autoApprove,
      mediaInitializing: mediaInitializing ?? this.mediaInitializing,
      mediaSharing: mediaSharing ?? this.mediaSharing,
      pendingRequests: pendingRequests ?? this.pendingRequests,
      lastEventType: lastEventType ?? this.lastEventType,
      deviceId: identical(deviceId, _unset) ? this.deviceId : deviceId as String?,
      localWsPort: localWsPort ?? this.localWsPort,
      registeredDeviceId: identical(registeredDeviceId, _unset)
          ? this.registeredDeviceId
          : registeredDeviceId as String?,
      registeringDevice: registeringDevice ?? this.registeringDevice,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
