part of 'terminal_view_model.dart';

extension _TerminalViewModelApprovalEvents on _TerminalViewModelEventsABase {
  void _handleApprovalRequest(Map<String, dynamic> body) {
    final aiSessionId = body['ai_session_id'] as String? ?? '';
    final terminalId = body['terminal_id'] as String? ?? '';
    final capabilityKey = body['capability_key'] as String? ?? '';
    if (aiSessionId.isEmpty || terminalId.isEmpty || capabilityKey.isEmpty) {
      return;
    }

    final request = TerminalApprovalRequest(
      aiSessionId: aiSessionId,
      terminalId: terminalId,
      requestId: body['request_id'] as String?,
      capabilityKey: capabilityKey,
      agentId: body['agent_id'] as String? ?? '',
      modelId: body['model_id'] as String? ?? '',
      cwd: body['cwd'] as String? ?? '',
      configuredMode: approvalModeFromJson(body['configured_mode'] as String?),
      supportedScopes: (body['supported_scopes'] as List<dynamic>? ?? const ['once', 'session'])
          .whereType<String>()
          .toList(growable: false),
      approvalKind: body['approval_kind'] as String?,
      shellCommand: body['shell_command'] as String?,
      shellPrefixCandidates:
          (body['shell_prefix_candidates'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(growable: false),
    );
    if (state.pendingApprovalRequests.any((item) => item.dedupeKey == request.dedupeKey)) {
      return;
    }

    state = state.copyWith(
      pendingApprovalRequests: [...state.pendingApprovalRequests, request],
      clearError: true,
    );
  }

  void _handleApprovalResolved(Map<String, dynamic> body) {
    final requestId = body['request_id'] as String? ?? '';
    final aiSessionId = body['ai_session_id'] as String? ?? '';
    final agentId = body['agent_id'] as String? ?? '';
    final capabilityKey = body['capability_key'] as String? ?? '';
    if ((requestId.isEmpty && aiSessionId.isEmpty) || capabilityKey.isEmpty) {
      return;
    }
    _removeApprovalRequest(
      requestId: requestId,
      aiSessionId: aiSessionId,
      agentId: agentId,
      capabilityKey: capabilityKey,
    );
  }
}
