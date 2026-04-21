import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_api_client.dart';
import 'backend_event_client.dart';
import 'desktop_local_client.dart';
import 'http_backend_api_client.dart';
import 'mock_backend_api_client.dart';

const _scene = String.fromEnvironment('SIRIX_SCENE', defaultValue: 'debug');
const _useMock = bool.fromEnvironment('SIRIX_USE_MOCK', defaultValue: false);
const _serverHost = String.fromEnvironment(
  'SIRIX_SERVER_HOST',
  defaultValue: '192.168.0.36',
);
const _apiBaseUrl = String.fromEnvironment(
  'SIRIX_API_BASE_URL',
  defaultValue: '',
);
const _desktopLocalHost = String.fromEnvironment(
  'SIRIX_DESKTOP_SERVER_HOST',
  defaultValue: '127.0.0.1',
);
const _desktopLocalPortStart = int.fromEnvironment(
  'SIRIX_DESKTOP_SERVER_PORT_START',
  defaultValue: _scene == 'release' ? 46121 : 46111,
);
const _desktopLocalPortEnd = int.fromEnvironment(
  'SIRIX_DESKTOP_SERVER_PORT_END',
  defaultValue: _scene == 'release' ? 46129 : 46119,
);
const useMockBackend = _useMock;
const _defaultBackendPort = _scene == 'release' ? 46120 : 46110;
final resolvedApiBaseUrl =
    _apiBaseUrl.isNotEmpty ? _apiBaseUrl : 'http://$_serverHost:$_defaultBackendPort';

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
