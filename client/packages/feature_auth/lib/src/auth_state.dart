import 'package:flutter/foundation.dart';

import 'package:infra_api/infra_api.dart';

@immutable
class AuthState {
  const AuthState({
    this.username = '',
    this.password = '',
    this.isLoading = false,
    this.errorMessage,
    this.session,
  });

  static const _unset = Object();

  final String username;
  final String password;
  final bool isLoading;
  final String? errorMessage;
  final AuthSession? session;

  bool get isAuthenticated => session != null;

  AuthState copyWith({
    String? username,
    String? password,
    bool? isLoading,
    String? errorMessage,
    Object? session = _unset,
    bool clearError = false,
  }) {
    return AuthState(
      username: username ?? this.username,
      password: password ?? this.password,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      session: identical(session, _unset) ? this.session : session as AuthSession?,
    );
  }
}
