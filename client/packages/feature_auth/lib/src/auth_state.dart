import 'package:flutter/foundation.dart';

import 'package:infra_api/infra_api.dart';

@immutable
class AuthState {
  const AuthState({
    this.username = '',
    this.password = '',
    this.isLoading = false,
    this.isInitializing = false,
    this.initialized = false,
    this.errorMessage,
    this.session,
  });

  static const _unset = Object();

  final String username;
  final String password;
  final bool isLoading;
  final bool isInitializing;
  final bool initialized;
  final String? errorMessage;
  final AuthSession? session;

  bool get isAuthenticated => session != null;

  AuthState copyWith({
    String? username,
    String? password,
    bool? isLoading,
    bool? isInitializing,
    bool? initialized,
    String? errorMessage,
    Object? session = _unset,
    bool clearError = false,
  }) {
    return AuthState(
      username: username ?? this.username,
      password: password ?? this.password,
      isLoading: isLoading ?? this.isLoading,
      isInitializing: isInitializing ?? this.isInitializing,
      initialized: initialized ?? this.initialized,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      session: identical(session, _unset) ? this.session : session as AuthSession?,
    );
  }
}
