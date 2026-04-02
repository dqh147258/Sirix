import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:infra_api/infra_api.dart';

import 'auth_session_store.dart';

abstract class AuthSessionController {
  Future<AuthSession?> restore();

  Future<AuthSession> login({
    required String username,
    required String password,
  });

  Future<AuthSession> register({
    required String username,
    required String password,
  });

  Future<void> logout();
}

class MobileAuthSessionController implements AuthSessionController {
  MobileAuthSessionController(
    this._apiClient,
    this._store,
    this._clientType,
  );

  final BackendApiClient _apiClient;
  final AuthSessionStore _store;
  final String _clientType;

  @override
  Future<AuthSession?> restore() async {
    final stored = await _store.load(_clientType);
    if (stored == null) {
      return null;
    }

    try {
      final refreshed = await _apiClient.refresh(refreshToken: stored.refreshToken);
      await _store.save(_clientType, refreshed);
      return refreshed;
    } catch (error) {
      if (_isInvalidRefreshError(error)) {
        await _store.clear(_clientType);
      }
      return null;
    }
  }

  @override
  Future<AuthSession> login({
    required String username,
    required String password,
  }) async {
    final session = await _apiClient.login(
      username: username,
      password: password,
      clientType: _clientType,
    );
    await _store.save(_clientType, session);
    return session;
  }

  @override
  Future<AuthSession> register({
    required String username,
    required String password,
  }) async {
    final session = await _apiClient.register(
      username: username,
      password: password,
    );
    await _store.save(_clientType, session);
    return session;
  }

  @override
  Future<void> logout() {
    return _store.clear(_clientType);
  }
}

class DesktopAuthSessionController implements AuthSessionController {
  DesktopAuthSessionController(this._localClient);

  final DesktopLocalClient _localClient;

  @override
  Future<AuthSession?> restore() {
    return _localClient.getAuthSession();
  }

  @override
  Future<AuthSession> login({
    required String username,
    required String password,
  }) {
    return _localClient.login(username: username, password: password);
  }

  @override
  Future<AuthSession> register({
    required String username,
    required String password,
  }) {
    return _localClient.register(username: username, password: password);
  }

  @override
  Future<void> logout() {
    return _localClient.logout();
  }
}

final authSessionStoreProvider = Provider<AuthSessionStore>((_) {
  return AuthSessionStore();
});

final authSessionControllerProvider = Provider.family<AuthSessionController, String>((
  ref,
  clientType,
) {
  if (clientType == 'desktop') {
    final localClient = ref.watch(desktopLocalClientProvider);
    return DesktopAuthSessionController(localClient);
  }

  final apiClient = ref.watch(backendApiClientProvider);
  final store = ref.watch(authSessionStoreProvider);
  return MobileAuthSessionController(apiClient, store, clientType);
});

bool _isInvalidRefreshError(Object error) {
  final message = error.toString();
  return message.contains('HTTP 401') ||
      message.contains('HTTP 403') ||
      message.contains('AUTH_TOKEN_EXPIRED');
}
