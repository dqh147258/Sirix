import 'models.dart';

abstract class BackendApiClient {
  Future<AuthSession> register({
    required String username,
    required String password,
  });

  Future<AuthSession> login({
    required String username,
    required String password,
    required String clientType,
  });

  Future<AuthSession> refresh({
    required String refreshToken,
  });

  Future<DeviceSummary> registerDevice({
    required String accessToken,
    required String deviceName,
    required String platform,
    required String clientVersion,
    String? preferredDeviceId,
  });

  Future<List<DeviceSummary>> listMyDevices({
    required String accessToken,
  });

  Future<DeviceSummary> updateDeviceAutoApprove({
    required String accessToken,
    required String deviceId,
    required bool autoApprove,
  });

  Future<RemoteSessionSummary> createConnectionRequest({
    required String accessToken,
    required String targetDeviceId,
    String initialQualityProfile = 'p720',
  });

  Future<List<ScreenSnapshot>> listSnapshots({
    required String accessToken,
    required String deviceId,
    bool forceRefresh = false,
  });

  Future<void> pauseSession({
    required String accessToken,
    required String sessionId,
  });

  Future<void> resumeSession({
    required String accessToken,
    required String sessionId,
  });

  Future<void> terminateSession({
    required String accessToken,
    required String sessionId,
  });

  Future<void> switchScreen({
    required String accessToken,
    required String sessionId,
    required String screenId,
  });

  Future<void> updateSessionQuality({
    required String accessToken,
    required String sessionId,
    required bool autoMode,
    String? profile,
  });

  Future<void> sendMobileWebrtcSignal({
    required String accessToken,
    required String sessionId,
    required WebrtcSignalType signalType,
    String? sdp,
    Map<String, dynamic>? candidate,
  });

  Future<TerminalSessionSummary> createTerminal({
    required String accessToken,
    required String targetDeviceId,
    required int cols,
    required int rows,
    String? cwd,
    String? shell,
    String? title,
  });

  Future<List<TerminalSessionSummary>> listTerminals({
    required String accessToken,
    String? deviceId,
  });

  Future<void> closeTerminal({
    required String accessToken,
    required String terminalId,
  });

  Future<void> resolveAiApproval({
    required String accessToken,
    required String sessionId,
    String? requestId,
    required String capabilityKey,
    required String agentId,
    required String decision,
    required String scope,
    String? prefix,
  });
}
