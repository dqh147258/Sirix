import 'dart:convert';

import 'package:http/http.dart' as http;

import 'backend_api_client.dart';
import 'models.dart';

class HttpBackendApiClient implements BackendApiClient {
  HttpBackendApiClient({required String baseUrl})
      : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  final String _baseUrl;

  @override
  Future<AuthSession> register({
    required String username,
    required String password,
  }) async {
    final json = await _post(
      '/api/v1/auth/register',
      body: {
        'username': username,
        'password': password,
      },
    );
    return AuthSession(
      userId: json['user_id'] as String,
      username: json['username'] as String,
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
    );
  }

  @override
  Future<AuthSession> login({
    required String username,
    required String password,
    required String clientType,
  }) async {
    final json = await _post(
      '/api/v1/auth/login',
      body: {
        'username': username,
        'password': password,
        'client_type': clientType,
      },
    );
    return AuthSession(
      userId: json['user_id'] as String,
      username: json['username'] as String,
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
    );
  }

  @override
  Future<DeviceSummary> registerDevice({
    required String accessToken,
    required String deviceName,
    required String platform,
    required String clientVersion,
    String? preferredDeviceId,
  }) async {
    final response = await _post(
      '/api/v1/devices/register',
      accessToken: accessToken,
      body: {
        'device_name': deviceName,
        'platform': platform,
        'client_version': clientVersion,
        if (preferredDeviceId != null) 'preferred_device_id': preferredDeviceId,
      },
    );

    return _deviceFromResponse(response);
  }

  @override
  Future<List<DeviceSummary>> listMyDevices({required String accessToken}) async {
    final response = await _get('/api/v1/devices/my', accessToken: accessToken);
    return (response as List<dynamic>).map((entry) {
      return _deviceFromResponse(entry as Map<String, dynamic>);
    }).toList(growable: false);
  }

  @override
  Future<DeviceSummary> updateDeviceAutoApprove({
    required String accessToken,
    required String deviceId,
    required bool autoApprove,
  }) async {
    final response = await _patch(
      '/api/v1/devices/$deviceId/settings',
      accessToken: accessToken,
      body: {
        'auto_approve_screen_share': autoApprove,
      },
    );

    return DeviceSummary(
      id: response['device_id'] as String,
      deviceName: '',
      platform: '',
      clientVersion: '',
      autoApproveScreenShare: response['auto_approve_screen_share'] as bool? ?? autoApprove,
      online: true,
    );
  }

  @override
  Future<RemoteSessionSummary> createConnectionRequest({
    required String accessToken,
    required String targetDeviceId,
    String initialQualityProfile = 'p720',
  }) async {
    final response = await _post(
      '/api/v1/connections/requests',
      accessToken: accessToken,
      body: {
        'target_device_id': targetDeviceId,
        'initial_quality_profile': initialQualityProfile,
      },
    );

    return RemoteSessionSummary(
      requestId: response['request_id'] as String,
      sessionId: response['session_id'] as String,
      state: response['state'] as String,
      targetDeviceId: targetDeviceId,
    );
  }

  @override
  Future<List<ScreenSnapshot>> listSnapshots({
    required String accessToken,
    required String deviceId,
  }) async {
    final response = await _get(
      '/api/v1/devices/$deviceId/snapshots',
      accessToken: accessToken,
    );

    return (response as List<dynamic>).map((entry) {
      final json = entry as Map<String, dynamic>;
      return ScreenSnapshot(
        screenId: json['screen_id'] as String,
        name: json['name'] as String? ?? json['screen_id'] as String,
        width: json['width'] as int? ?? 0,
        height: json['height'] as int? ?? 0,
        previewBase64: json['preview_base64'] as String? ?? '',
      );
    }).toList(growable: false);
  }

  @override
  Future<void> pauseSession({
    required String accessToken,
    required String sessionId,
  }) async {
    await _post('/api/v1/sessions/$sessionId/pause', accessToken: accessToken);
  }

  @override
  Future<void> resumeSession({
    required String accessToken,
    required String sessionId,
  }) async {
    await _post('/api/v1/sessions/$sessionId/resume', accessToken: accessToken);
  }

  @override
  Future<void> terminateSession({
    required String accessToken,
    required String sessionId,
  }) async {
    await _post('/api/v1/sessions/$sessionId/terminate', accessToken: accessToken);
  }

  @override
  Future<void> switchScreen({
    required String accessToken,
    required String sessionId,
    required String screenId,
  }) async {
    await _post(
      '/api/v1/sessions/$sessionId/switch-screen',
      accessToken: accessToken,
      body: {'screen_id': screenId},
    );
  }

  @override
  Future<void> updateSessionQuality({
    required String accessToken,
    required String sessionId,
    required bool autoMode,
    String? profile,
  }) async {
    await _post(
      '/api/v1/sessions/$sessionId/quality',
      accessToken: accessToken,
      body: {
        'mode': autoMode ? 'auto' : 'manual',
        'profile': profile,
      },
    );
  }

  @override
  Future<void> sendMobileWebrtcSignal({
    required String accessToken,
    required String sessionId,
    required WebrtcSignalType signalType,
    String? sdp,
    Map<String, dynamic>? candidate,
  }) async {
    await _post(
      '/api/v1/webrtc/signal',
      accessToken: accessToken,
      body: {
        'session_id': sessionId,
        'role': 'mobile',
        'signal_type': signalType.apiValue,
        'sdp': sdp,
        'candidate': candidate,
      },
    );
  }

  Future<dynamic> _get(
    String path, {
    String? accessToken,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await http.get(uri, headers: _headers(accessToken));
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    String? accessToken,
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await http.post(
      uri,
      headers: _headers(accessToken),
      body: jsonEncode(body ?? <String, dynamic>{}),
    );

    final decoded = _decode(response);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _patch(
    String path, {
    required String accessToken,
    required Map<String, dynamic> body,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await http.patch(
      uri,
      headers: _headers(accessToken),
      body: jsonEncode(body),
    );

    final decoded = _decode(response);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Map<String, String> _headers(String? accessToken) {
    return {
      'Content-Type': 'application/json',
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    };
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}: ${response.body}');
    }

    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }

    return jsonDecode(response.body);
  }

  DeviceSummary _deviceFromResponse(Map<String, dynamic> json) {
    return DeviceSummary(
      id: json['id'] as String,
      deviceName: json['device_name'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      clientVersion: json['client_version'] as String? ?? '',
      autoApproveScreenShare: json['auto_approve_screen_share'] as bool? ?? false,
      online: json['online'] as bool? ?? false,
    );
  }
}
