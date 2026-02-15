import 'package:flutter/foundation.dart';

enum UiLoadStatus {
  idle,
  loading,
  success,
  failure,
}

@immutable
class AsyncUiState<T> {
  const AsyncUiState({
    this.status = UiLoadStatus.idle,
    this.data,
    this.errorMessage,
  });

  final UiLoadStatus status;
  final T? data;
  final String? errorMessage;

  bool get isLoading => status == UiLoadStatus.loading;

  AsyncUiState<T> copyWith({
    UiLoadStatus? status,
    T? data,
    String? errorMessage,
  }) {
    return AsyncUiState<T>(
      status: status ?? this.status,
      data: data ?? this.data,
      errorMessage: errorMessage,
    );
  }
}
