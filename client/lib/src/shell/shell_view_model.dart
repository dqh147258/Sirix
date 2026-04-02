import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'shell_state.dart';

enum ShellMode {
  desktop,
  mobile,
}

class ShellViewModel extends BaseViewModel<ShellState> {
  ShellViewModel() : super(const ShellState());

  void selectIndex(int value) {
    if (value == state.selectedIndex) {
      return;
    }
    state = state.copyWith(selectedIndex: value);
  }

  void attachRemoteSession(RemoteSessionSummary session) {
    state = state.copyWith(
      selectedIndex: 1,
      activeRemoteSession: session,
    );
  }

  void clearRemoteSession() {
    state = state.copyWith(
      clearActiveRemoteSession: true,
      selectedIndex: 0,
    );
  }

  void reset() {
    state = const ShellState();
  }
}

final shellViewModelProvider =
    StateNotifierProvider.family<ShellViewModel, ShellState, ShellMode>(
  (_, __) => ShellViewModel(),
);
