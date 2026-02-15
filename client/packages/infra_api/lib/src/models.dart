import 'package:flutter/foundation.dart';

@immutable
class AuthSession {
  const AuthSession({
    required this.userId,
    required this.username,
    required this.accessToken,
    required this.refreshToken,
  });

  final String userId;
  final String username;
  final String accessToken;
  final String refreshToken;
}

@immutable
class DeviceSummary {
  const DeviceSummary({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.clientVersion,
    required this.autoApproveScreenShare,
    required this.online,
  });

  final String id;
  final String deviceName;
  final String platform;
  final String clientVersion;
  final bool autoApproveScreenShare;
  final bool online;

  DeviceSummary copyWith({
    bool? autoApproveScreenShare,
    bool? online,
  }) {
    return DeviceSummary(
      id: id,
      deviceName: deviceName,
      platform: platform,
      clientVersion: clientVersion,
      autoApproveScreenShare: autoApproveScreenShare ?? this.autoApproveScreenShare,
      online: online ?? this.online,
    );
  }
}

@immutable
class RemoteSessionSummary {
  const RemoteSessionSummary({
    required this.requestId,
    required this.sessionId,
    required this.state,
    required this.targetDeviceId,
  });

  final String requestId;
  final String sessionId;
  final String state;
  final String targetDeviceId;
}

@immutable
class ScreenSnapshot {
  const ScreenSnapshot({
    required this.screenId,
    required this.name,
    required this.width,
    required this.height,
    required this.previewBase64,
  });

  final String screenId;
  final String name;
  final int width;
  final int height;
  final String previewBase64;
}

enum WebrtcSignalType {
  offer,
  answer,
  iceCandidate,
}

extension WebrtcSignalTypeApiValue on WebrtcSignalType {
  String get apiValue {
    switch (this) {
      case WebrtcSignalType.offer:
        return 'offer';
      case WebrtcSignalType.answer:
        return 'answer';
      case WebrtcSignalType.iceCandidate:
        return 'ice_candidate';
    }
  }
}
