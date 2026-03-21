import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_api_client.dart';
import 'backend_event_client.dart';
import 'desktop_local_client.dart';
import 'http_backend_api_client.dart';
import 'mock_backend_api_client.dart';

const _useMock = bool.fromEnvironment('FREELOOM_USE_MOCK', defaultValue: false);
const _serverHost = String.fromEnvironment(
  'FREELOOM_SERVER_HOST',
  defaultValue: '192.168.0.36',
);
const _apiBaseUrl = String.fromEnvironment(
  'FREELOOM_API_BASE_URL',
  defaultValue: '',
);
const _desktopLocalHost = String.fromEnvironment(
  'FREELOOM_DESKTOP_SERVER_HOST',
  defaultValue: '127.0.0.1',
);
const _desktopLocalPortStart = int.fromEnvironment(
  'FREELOOM_DESKTOP_SERVER_PORT_START',
  defaultValue: 9700,
);
const _desktopLocalPortEnd = int.fromEnvironment(
  'FREELOOM_DESKTOP_SERVER_PORT_END',
  defaultValue: 9710,
);
const useMockBackend = _useMock;
final resolvedApiBaseUrl = _apiBaseUrl.isNotEmpty ? _apiBaseUrl : 'http://$_serverHost:8080';

final backendApiClientProvider = Provider<BackendApiClient>((ref) {
  if (_useMock) {
    return MockBackendApiClient();
  }
  return HttpBackendApiClient(baseUrl: resolvedApiBaseUrl);
});

final backendEventClientProvider = Provider<BackendEventClient?>((ref) {
  if (_useMock) {
    return null;
  }
  return BackendEventClient(baseUrl: resolvedApiBaseUrl);
});

final desktopLocalClientProvider = Provider<DesktopLocalClient>((ref) {
  return DesktopLocalClient(
    host: _desktopLocalHost,
    portStart: _desktopLocalPortStart,
    portEnd: _desktopLocalPortEnd,
  );
});
