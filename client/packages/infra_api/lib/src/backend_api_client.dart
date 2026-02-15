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
}
