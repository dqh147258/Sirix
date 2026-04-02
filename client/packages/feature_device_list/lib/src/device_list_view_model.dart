import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'device_list_state.dart';

class DeviceListViewModel extends BaseViewModel<DeviceListState> {
  DeviceListViewModel(this._apiClient) : super(const DeviceListState());

  final BackendApiClient _apiClient;

  Future<void> load(String accessToken) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final devices = await _apiClient.listMyDevices(accessToken: accessToken);
      state = state.copyWith(loading: false, devices: devices, clearError: true);
    } catch (error) {
      state = state.copyWith(
        loading: false,
        errorMessage: '${AppLocalizations.current.deviceListLoadFailed}: $error',
      );
    }
  }

  Future<void> toggleAutoApprove({
    required String accessToken,
    required DeviceSummary device,
    required bool nextValue,
  }) async {
    try {
      final updated = await _apiClient.updateDeviceAutoApprove(
        accessToken: accessToken,
        deviceId: device.id,
        autoApprove: nextValue,
      );
      final devices = [
        for (final current in state.devices)
          if (current.id == updated.id)
            current.copyWith(
              autoApproveScreenShare: updated.autoApproveScreenShare,
              online: updated.online,
            )
          else
            current,
      ];
      state = state.copyWith(devices: devices, clearError: true);
    } catch (error) {
      state = state.copyWith(
        errorMessage: '${AppLocalizations.current.updateDeviceSettingsFailed}: $error',
      );
    }
  }

  Future<RemoteSessionSummary?> connectToDevice({
    required String accessToken,
    required String deviceId,
  }) async {
    try {
      final session = await _apiClient.createConnectionRequest(
        accessToken: accessToken,
        targetDeviceId: deviceId,
      );
      if (session.state == 'terminated') {
        AppLogger.warn('connect request terminated before attach: ${session.sessionId}');
        state = state.copyWith(
          errorMessage: AppLocalizations.current.desktopUnavailableHint,
        );
        return null;
      }
      AppLogger.info('connect requested: ${session.sessionId} targetDeviceId=$deviceId');
      return session;
    } catch (error) {
      AppLogger.error('connect request failed targetDeviceId=$deviceId error=$error');
      state = state.copyWith(
        errorMessage: '${AppLocalizations.current.connectRequestFailed}: $error',
      );
      return null;
    }
  }
}

final deviceListViewModelProvider =
    StateNotifierProvider<DeviceListViewModel, DeviceListState>((ref) {
  final apiClient = ref.watch(backendApiClientProvider);
  return DeviceListViewModel(apiClient);
});
