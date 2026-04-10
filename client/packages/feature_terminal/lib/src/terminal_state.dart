import 'package:flutter/foundation.dart';

import 'package:infra_api/infra_api.dart';

@immutable
class TerminalApprovalRequest {
  const TerminalApprovalRequest({
    required this.aiSessionId,
    required this.terminalId,
    required this.capabilityKey,
    required this.agentId,
    required this.modelId,
    required this.cwd,
    required this.configuredMode,
  });

  final String aiSessionId;
  final String terminalId;
  final String capabilityKey;
  final String agentId;
  final String modelId;
  final String cwd;
  final ApprovalMode configuredMode;

  String get dedupeKey => '$aiSessionId::$capabilityKey';
}

@immutable
class TerminalState {
  const TerminalState({
    this.terminals = const [],
    this.pendingApprovalRequests = const [],
    this.activeTerminalId,
    this.errorMessage,
    this.loading = false,
    this.connecting = false,
  });

  final List<TerminalSessionSummary> terminals;
  final List<TerminalApprovalRequest> pendingApprovalRequests;
  final String? activeTerminalId;
  final String? errorMessage;
  final bool loading;
  final bool connecting;

  TerminalApprovalRequest? get activeApprovalRequest {
    if (pendingApprovalRequests.isEmpty) {
      return null;
    }
    final activeId = activeTerminalId;
    if (activeId != null) {
      for (final request in pendingApprovalRequests) {
        if (request.terminalId == activeId) {
          return request;
        }
      }
    }
    return pendingApprovalRequests.first;
  }

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
    List<TerminalApprovalRequest>? pendingApprovalRequests,
    String? activeTerminalId,
    String? errorMessage,
    bool? loading,
    bool? connecting,
    bool clearActiveTerminalId = false,
    bool clearError = false,
  }) {
    return TerminalState(
      terminals: terminals ?? this.terminals,
      pendingApprovalRequests: pendingApprovalRequests ?? this.pendingApprovalRequests,
      activeTerminalId:
          clearActiveTerminalId ? null : (activeTerminalId ?? this.activeTerminalId),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      loading: loading ?? this.loading,
      connecting: connecting ?? this.connecting,
    );
  }
}
