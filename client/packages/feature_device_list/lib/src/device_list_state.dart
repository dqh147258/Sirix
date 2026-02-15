import 'package:flutter/foundation.dart';

import 'package:infra_api/infra_api.dart';

@immutable
class DeviceListState {
  const DeviceListState({
    this.loading = false,
    this.errorMessage,
    this.devices = const [],
  });

  final bool loading;
  final String? errorMessage;
  final List<DeviceSummary> devices;

  DeviceListState copyWith({
    bool? loading,
    String? errorMessage,
    List<DeviceSummary>? devices,
    bool clearError = false,
  }) {
    return DeviceListState(
      loading: loading ?? this.loading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      devices: devices ?? this.devices,
    );
  }
}
