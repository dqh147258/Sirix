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
    this.source = 'unknown',
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
  final String source;
  final String shell;
  final String cwd;
  final String state;
  final int cols;
  final int rows;
  final DateTime createdAt;
  final DateTime? closedAt;

  TerminalSessionSummary copyWith({
    String? title,
    String? source,
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
      source: source ?? this.source,
      shell: shell ?? this.shell,
      cwd: cwd ?? this.cwd,
      state: state ?? this.state,
      cols: cols ?? this.cols,
      rows: rows ?? this.rows,
      createdAt: createdAt,
      closedAt: clearClosedAt ? null : (closedAt ?? this.closedAt),
    );
  }

  bool get isHostedTerminal {
    // Remote/mobile snapshots do not currently emit an explicit source field,
    // so the dedicated Sirix Terminal title remains the compatibility fallback.
    return source == 'hosted' || title.trim().toLowerCase() == 'sirix terminal';
  }
}

enum WebrtcSignalType {
  offer,
  answer,
  iceCandidate,
}

@immutable
class LocalStatusOverview {
  const LocalStatusOverview({
    required this.generatedAt,
    required this.runtime,
    required this.backend,
    required this.ai,
    required this.terminals,
    required this.mcp,
  });

  final DateTime? generatedAt;
  final LocalRuntimeStatus runtime;
  final LocalBackendStatus backend;
  final LocalAiStatus ai;
  final LocalTerminalStatus terminals;
  final LocalMcpStatusGroup mcp;

  factory LocalStatusOverview.fromJson(Map<String, dynamic> json) {
    return LocalStatusOverview(
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? ''),
      runtime: LocalRuntimeStatus.fromJson(
        (json['runtime'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
      backend: LocalBackendStatus.fromJson(
        (json['backend'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
      ai: LocalAiStatus.fromJson(
        (json['ai'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
      terminals: LocalTerminalStatus.fromJson(
        (json['terminals'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
      mcp: LocalMcpStatusGroup.fromJson(
        (json['mcp'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
    );
  }
}

@immutable
class LocalRuntimeStatus {
  const LocalRuntimeStatus({
    this.localWsPort = 0,
    this.desktopClientConnections = 0,
    this.autoApproveScreenShare = false,
    this.loggingEnabled = true,
    this.backendEventStreamConnected = false,
    this.backendLastHealthyAt,
  });

  final int localWsPort;
  final int desktopClientConnections;
  final bool autoApproveScreenShare;
  final bool loggingEnabled;
  final bool backendEventStreamConnected;
  final DateTime? backendLastHealthyAt;

  factory LocalRuntimeStatus.fromJson(Map<String, dynamic> json) {
    return LocalRuntimeStatus(
      localWsPort: (json['local_ws_port'] as num?)?.toInt() ?? 0,
      desktopClientConnections:
          (json['desktop_client_connections'] as num?)?.toInt() ?? 0,
      autoApproveScreenShare:
          json['auto_approve_screen_share'] as bool? ?? false,
      loggingEnabled: json['logging_enabled'] as bool? ?? true,
      backendEventStreamConnected:
          json['backend_event_stream_connected'] as bool? ?? false,
      backendLastHealthyAt: DateTime.tryParse(
        json['backend_last_healthy_at'] as String? ?? '',
      ),
    );
  }
}

@immutable
class LocalBackendStatus {
  const LocalBackendStatus({
    this.connected = false,
    this.lastHealthyAt,
  });

  final bool connected;
  final DateTime? lastHealthyAt;

  factory LocalBackendStatus.fromJson(Map<String, dynamic> json) {
    return LocalBackendStatus(
      connected: json['connected'] as bool? ?? false,
      lastHealthyAt: DateTime.tryParse(json['last_healthy_at'] as String? ?? ''),
    );
  }
}

@immutable
class LocalAiStatus {
  const LocalAiStatus({
    this.activeSessions = 0,
  });

  final int activeSessions;

  factory LocalAiStatus.fromJson(Map<String, dynamic> json) {
    return LocalAiStatus(
      activeSessions: (json['active_sessions'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class LocalTerminalStatus {
  const LocalTerminalStatus({
    this.activeTerminals = 0,
    this.standalonePageDeprecated = false,
  });

  final int activeTerminals;
  final bool standalonePageDeprecated;

  factory LocalTerminalStatus.fromJson(Map<String, dynamic> json) {
    return LocalTerminalStatus(
      activeTerminals: (json['active_terminals'] as num?)?.toInt() ?? 0,
      standalonePageDeprecated:
          json['standalone_page_deprecated'] as bool? ?? false,
    );
  }
}

@immutable
class LocalMcpStatusGroup {
  const LocalMcpStatusGroup({
    this.lastProbeAt,
    this.activeCount = 0,
    this.errorCount = 0,
    this.servers = const [],
  });

  final DateTime? lastProbeAt;
  final int activeCount;
  final int errorCount;
  final List<LocalMcpServerStatus> servers;

  factory LocalMcpStatusGroup.fromJson(Map<String, dynamic> json) {
    return LocalMcpStatusGroup(
      lastProbeAt: DateTime.tryParse(json['last_probe_at'] as String? ?? ''),
      activeCount: (json['active_count'] as num?)?.toInt() ?? 0,
      errorCount: (json['error_count'] as num?)?.toInt() ?? 0,
      servers: (json['servers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(LocalMcpServerStatus.fromJson)
          .toList(growable: false),
    );
  }
}

@immutable
class LocalMcpServerStatus {
  const LocalMcpServerStatus({
    required this.id,
    required this.title,
    required this.transport,
    required this.enabled,
    required this.active,
    required this.healthy,
    this.error,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String transport;
  final bool enabled;
  final bool active;
  final bool healthy;
  final String? error;
  final DateTime? updatedAt;

  factory LocalMcpServerStatus.fromJson(Map<String, dynamic> json) {
    return LocalMcpServerStatus(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      transport: json['transport'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      active: json['active'] as bool? ?? false,
      healthy: json['healthy'] as bool? ?? false,
      error: json['error'] as String?,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }
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
