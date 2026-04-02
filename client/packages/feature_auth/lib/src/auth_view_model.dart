import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';

import 'auth_session_controller.dart';
import 'auth_state.dart';

class AuthViewModel extends BaseViewModel<AuthState> {
  AuthViewModel({
    required AuthSessionController sessionController,
    required this.clientType,
  })  : _sessionController = sessionController,
        super(const AuthState());

  final AuthSessionController _sessionController;
  final String clientType;

  Future<void> initialize() async {
    if (state.isInitializing || state.initialized) {
      return;
    }

    state = state.copyWith(isInitializing: true, clearError: true);
    try {
      final session = await _sessionController.restore();
      state = state.copyWith(
        isInitializing: false,
        initialized: true,
        session: session,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isInitializing: false,
        initialized: true,
        session: null,
        errorMessage: AppLocalizations.current.loginFailed('$error'),
      );
    }
  }

  void setUsername(String value) {
    state = state.copyWith(username: value, clearError: true);
  }

  void setPassword(String value) {
    state = state.copyWith(password: value, clearError: true);
  }

  Future<void> login() async {
    if (state.username.trim().isEmpty || state.password.isEmpty) {
      state = state.copyWith(errorMessage: AppLocalizations.current.enterUsernamePassword);
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final session = await _sessionController.login(
        username: state.username,
        password: state.password,
      );
      state = state.copyWith(
        isLoading: false,
        initialized: true,
        session: session,
        clearError: true,
      );
      AppLogger.info('login success: ${session.username}');
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        initialized: true,
        errorMessage: AppLocalizations.current.loginFailed('$error'),
      );
    }
  }

  Future<void> register() async {
    if (state.username.trim().isEmpty || state.password.length < 8) {
      state = state.copyWith(errorMessage: AppLocalizations.current.registerValidation);
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final session = await _sessionController.register(
        username: state.username,
        password: state.password,
      );
      state = state.copyWith(
        isLoading: false,
        initialized: true,
        session: session,
        clearError: true,
      );
      AppLogger.info('register success: ${session.username}');
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        initialized: true,
        errorMessage: AppLocalizations.current.registerFailed('$error'),
      );
    }
  }

  Future<void> logout() async {
    try {
      await _sessionController.logout();
    } catch (error) {
      AppLogger.warn('logout failed: $error');
    }
    state = state.copyWith(
      session: null,
      password: '',
      initialized: true,
      clearError: true,
    );
  }
}

final authViewModelProvider =
    StateNotifierProvider.family<AuthViewModel, AuthState, String>(
  (ref, clientType) {
    final sessionController = ref.watch(authSessionControllerProvider(clientType));
    return AuthViewModel(sessionController: sessionController, clientType: clientType);
  },
);
