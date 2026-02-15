import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'auth_state.dart';

class AuthViewModel extends BaseViewModel<AuthState> {
  AuthViewModel({
    required BackendApiClient apiClient,
    required this.clientType,
  })  : _apiClient = apiClient,
        super(const AuthState());

  final BackendApiClient _apiClient;
  final String clientType;

  void setUsername(String value) {
    state = state.copyWith(username: value, clearError: true);
  }

  void setPassword(String value) {
    state = state.copyWith(password: value, clearError: true);
  }

  Future<void> login() async {
    if (state.username.trim().isEmpty || state.password.isEmpty) {
      state = state.copyWith(errorMessage: '请输入用户名和密码');
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final session = await _apiClient.login(
        username: state.username,
        password: state.password,
        clientType: clientType,
      );
      state = state.copyWith(isLoading: false, session: session, clearError: true);
      AppLogger.info('login success: ${session.username}');
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '登录失败: $error',
      );
    }
  }

  Future<void> register() async {
    if (state.username.trim().isEmpty || state.password.length < 8) {
      state = state.copyWith(errorMessage: '用户名不能为空，密码至少8位');
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final session = await _apiClient.register(
        username: state.username,
        password: state.password,
      );
      state = state.copyWith(isLoading: false, session: session, clearError: true);
      AppLogger.info('register success: ${session.username}');
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '注册失败: $error',
      );
    }
  }

  void logout() {
    state = state.copyWith(session: null, password: '', clearError: true);
  }
}

final authViewModelProvider =
    StateNotifierProvider.family<AuthViewModel, AuthState, String>(
  (ref, clientType) {
    final apiClient = ref.watch(backendApiClientProvider);
    return AuthViewModel(apiClient: apiClient, clientType: clientType);
  },
);
