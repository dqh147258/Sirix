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

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      userId: json['user_id'] as String? ?? json['userId'] as String? ?? '',
      username: json['username'] as String? ?? '',
      accessToken: json['access_token'] as String? ?? json['accessToken'] as String? ?? '',
      refreshToken: json['refresh_token'] as String? ?? json['refreshToken'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      'username': username,
      'access_token': accessToken,
      'refresh_token': refreshToken,
    };
  }
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

@immutable
class TerminalSessionSummary {
  const TerminalSessionSummary({
    required this.id,
    required this.deviceId,
    required this.title,
    required this.shell,
    required this.cwd,
    required this.state,
    required this.cols,
    required this.rows,
    required this.createdAt,
    this.closedAt,
  });

  final String id;
  final String deviceId;
  final String title;
  final String shell;
  final String cwd;
  final String state;
  final int cols;
  final int rows;
  final DateTime createdAt;
  final DateTime? closedAt;

  TerminalSessionSummary copyWith({
    String? title,
    String? shell,
    String? cwd,
    String? state,
    int? cols,
    int? rows,
    DateTime? closedAt,
    bool clearClosedAt = false,
  }) {
    return TerminalSessionSummary(
      id: id,
      deviceId: deviceId,
      title: title ?? this.title,
      shell: shell ?? this.shell,
      cwd: cwd ?? this.cwd,
      state: state ?? this.state,
      cols: cols ?? this.cols,
      rows: rows ?? this.rows,
      createdAt: createdAt,
      closedAt: clearClosedAt ? null : (closedAt ?? this.closedAt),
    );
  }
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
