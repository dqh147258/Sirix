import 'package:flutter/foundation.dart';

import 'package:infra_api/infra_api.dart';

@immutable
class TerminalState {
  const TerminalState({
    this.terminals = const [],
    this.activeTerminalId,
    this.errorMessage,
    this.loading = false,
    this.connecting = false,
  });

  final List<TerminalSessionSummary> terminals;
  final String? activeTerminalId;
  final String? errorMessage;
  final bool loading;
  final bool connecting;

  TerminalSessionSummary? get activeTerminal {
    final activeId = activeTerminalId;
    if (activeId == null) {
      return terminals.isEmpty ? null : terminals.first;
    }

    for (final terminal in terminals) {
      if (terminal.id == activeId) {
        return terminal;
      }
    }
    return terminals.isEmpty ? null : terminals.first;
  }

  TerminalState copyWith({
    List<TerminalSessionSummary>? terminals,
    String? activeTerminalId,
    String? errorMessage,
    bool? loading,
    bool? connecting,
    bool clearActiveTerminalId = false,
    bool clearError = false,
  }) {
    return TerminalState(
      terminals: terminals ?? this.terminals,
      activeTerminalId:
          clearActiveTerminalId ? null : (activeTerminalId ?? this.activeTerminalId),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      loading: loading ?? this.loading,
      connecting: connecting ?? this.connecting,
    );
  }
}
