import 'package:uuid/uuid.dart';

import 'backend_api_client.dart';
import 'models.dart';

class MockBackendApiClient implements BackendApiClient {
  MockBackendApiClient();

  final Uuid _uuid = const Uuid();
  final Map<String, AuthSession> _users = {};
  final List<DeviceSummary> _devices = [
    const DeviceSummary(
      id: 'dev-1',
      deviceName: 'Mac Studio',
      platform: 'macos',
      clientVersion: '0.1.0',
      autoApproveScreenShare: false,
      online: true,
    ),
    const DeviceSummary(
      id: 'dev-2',
      deviceName: 'Windows Workstation',
      platform: 'windows',
      clientVersion: '0.1.0',
      autoApproveScreenShare: false,
      online: true,
    ),
    const DeviceSummary(
      id: 'dev-3',
      deviceName: 'Ubuntu Workstation',
      platform: 'linux',
      clientVersion: '0.1.0',
      autoApproveScreenShare: false,
      online: true,
    ),
  ];

  @override
  Future<AuthSession> login({
    required String username,
    required String password,
    required String clientType,
  }) async {
    final key = username.toLowerCase().trim();
    final existing = _users[key];
    if (existing != null) {
      return existing;
    }
    return register(username: username, password: password);
  }

  @override
  Future<AuthSession> refresh({
    required String refreshToken,
  }) async {
    AuthSession? existing;
    for (final session in _users.values) {
      if (session.refreshToken == refreshToken) {
        existing = session;
        break;
      }
    }
    if (existing == null) {
      throw StateError('refresh token is invalid');
    }

    final refreshed = AuthSession(
      userId: existing.userId,
      username: existing.username,
      accessToken: _uuid.v4(),
      refreshToken: _uuid.v4(),
    );
    _users[existing.username.toLowerCase().trim()] = refreshed;
    return refreshed;
  }

  @override
  Future<AuthSession> register({
    required String username,
    required String password,
  }) async {
    final session = AuthSession(
      userId: _uuid.v4(),
      username: username.trim(),
      accessToken: _uuid.v4(),
      refreshToken: _uuid.v4(),
    );
    _users[username.toLowerCase().trim()] = session;
    return session;
  }

  @override
  Future<DeviceSummary> registerDevice({
    required String accessToken,
    required String deviceName,
    required String platform,
    required String clientVersion,
    String? preferredDeviceId,
  }) async {
    final deviceId = preferredDeviceId ?? _uuid.v4();
    final index = _devices.indexWhere((device) => device.id == deviceId);

    if (index == -1) {
      final created = DeviceSummary(
        id: deviceId,
        deviceName: deviceName,
        platform: platform,
        clientVersion: clientVersion,
        autoApproveScreenShare: false,
        online: true,
      );
      _devices.insert(0, created);
      return created;
    }

    final existing = _devices[index];
    final updated = DeviceSummary(
      id: existing.id,
      deviceName: deviceName,
      platform: platform,
      clientVersion: clientVersion,
      autoApproveScreenShare: existing.autoApproveScreenShare,
      online: true,
    );
    _devices[index] = updated;
    return updated;
  }

  @override
  Future<List<DeviceSummary>> listMyDevices({required String accessToken}) async {
    return _devices;
  }

  @override
  Future<DeviceSummary> updateDeviceAutoApprove({
    required String accessToken,
    required String deviceId,
    required bool autoApprove,
  }) async {
    final index = _devices.indexWhere((device) => device.id == deviceId);
    if (index == -1) {
      throw StateError('device not found');
    }
    final updated = _devices[index].copyWith(autoApproveScreenShare: autoApprove);
    _devices[index] = updated;
    return updated;
  }

  @override
  Future<RemoteSessionSummary> createConnectionRequest({
    required String accessToken,
    required String targetDeviceId,
    String initialQualityProfile = 'p720',
  }) async {
    return RemoteSessionSummary(
      requestId: _uuid.v4(),
      sessionId: _uuid.v4(),
      state: 'pending_approval',
      targetDeviceId: targetDeviceId,
    );
  }

  @override
  Future<List<ScreenSnapshot>> listSnapshots({
    required String accessToken,
    required String deviceId,
    bool forceRefresh = false,
  }) async {
    return const <ScreenSnapshot>[];
  }

  @override
  Future<void> pauseSession({
    required String accessToken,
    required String sessionId,
  }) async {}

  @override
  Future<void> resumeSession({
    required String accessToken,
    required String sessionId,
  }) async {}

  @override
  Future<void> terminateSession({
    required String accessToken,
    required String sessionId,
  }) async {}

  @override
  Future<void> switchScreen({
    required String accessToken,
    required String sessionId,
    required String screenId,
  }) async {}

  @override
  Future<void> updateSessionQuality({
    required String accessToken,
    required String sessionId,
    required bool autoMode,
    String? profile,
  }) async {}

  @override
  Future<void> sendMobileWebrtcSignal({
    required String accessToken,
    required String sessionId,
    required WebrtcSignalType signalType,
    String? sdp,
    Map<String, dynamic>? candidate,
  }) async {}

  @override
  Future<TerminalSessionSummary> createTerminal({
    required String accessToken,
    required String targetDeviceId,
    required int cols,
    required int rows,
    String? cwd,
    String? shell,
    String? title,
  }) async {
    throw UnsupportedError('mock backend does not support terminal creation');
  }

  @override
  Future<List<TerminalSessionSummary>> listTerminals({
    required String accessToken,
    String? deviceId,
  }) async {
    return const <TerminalSessionSummary>[];
  }

  @override
  Future<void> closeTerminal({
    required String accessToken,
    required String terminalId,
  }) async {}

  @override
  Future<void> resolveAiApproval({
    required String accessToken,
    required String sessionId,
    String? requestId,
    required String capabilityKey,
    required String agentId,
    required String decision,
    required String scope,
    String? approvalKind,
    String? prefix,
  }) async {}
}
