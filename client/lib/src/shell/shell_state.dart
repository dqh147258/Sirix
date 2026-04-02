import 'package:infra_api/infra_api.dart';

class ShellState {
  const ShellState({
    this.selectedIndex = 0,
    this.activeRemoteSession,
  });

  final int selectedIndex;
  final RemoteSessionSummary? activeRemoteSession;

  ShellState copyWith({
    int? selectedIndex,
    RemoteSessionSummary? activeRemoteSession,
    bool clearActiveRemoteSession = false,
  }) {
    return ShellState(
      selectedIndex: selectedIndex ?? this.selectedIndex,
      activeRemoteSession: clearActiveRemoteSession
          ? null
          : activeRemoteSession ?? this.activeRemoteSession,
    );
  }
}
