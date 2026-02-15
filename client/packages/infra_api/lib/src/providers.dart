import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_api_client.dart';
import 'backend_event_client.dart';
import 'desktop_local_client.dart';
import 'http_backend_api_client.dart';
import 'mock_backend_api_client.dart';

const _useMock = bool.fromEnvironment('FREELOOM_USE_MOCK', defaultValue: true);
const _apiBaseUrl = String.fromEnvironment(
  'FREELOOM_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8080',
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

final backendApiClientProvider = Provider<BackendApiClient>((ref) {
  if (_useMock) {
    return MockBackendApiClient();
  }
  return HttpBackendApiClient(baseUrl: _apiBaseUrl);
});

final backendEventClientProvider = Provider<BackendEventClient?>((ref) {
  if (_useMock) {
    return null;
  }
  return BackendEventClient(baseUrl: _apiBaseUrl);
});

final desktopLocalClientProvider = Provider<DesktopLocalClient>((ref) {
  return DesktopLocalClient(
    host: _desktopLocalHost,
    portStart: _desktopLocalPortStart,
    portEnd: _desktopLocalPortEnd,
  );
});
