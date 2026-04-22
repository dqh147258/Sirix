part of 'terminal_view_model.dart';

abstract class _TerminalViewModelEventsBBase extends _TerminalViewModelEventsABase {
  _TerminalViewModelEventsBBase({
    required super.apiClient,
    required super.eventClient,
    required super.desktopLocalClient,
    required super.sessionTerminalChannelController,
    required super.config,
  });

  Future<void> attachTerminal(String terminalId);

  @override
  List<int>? _decodeEventBytes(Map<String, dynamic> body) {
    final data = body['data_base64'] as String?;
    if (data == null) {
      return null;
    }

    return base64Decode(data);
  }

  @override
  List<int>? _decodeScreenSnapshotBytes(Map<String, dynamic> body) {
    final data = body['screen_data_base64'] as String?;
    if (data == null || data.isEmpty) {
      return null;
    }
    return base64Decode(data);
  }

  @override
  int? _resolveEventStreamSequence(Map<String, dynamic> body) {
    final value = body['stream_sequence'];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse('$value');
  }

  @override
  void _handleTerminalReady(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body) ?? '';
    if (terminalId.isEmpty) {
      return;
    }
    final readySignature = [
      terminalId,
      body['title'] as String? ?? '',
      body['source'] as String? ?? '',
      body['shell'] as String? ?? '',
      body['cwd'] as String? ?? '',
      body['state'] as String? ?? '',
      (body['cols'] as num?)?.toInt() ?? -1,
      (body['rows'] as num?)?.toInt() ?? -1,
      (body['latest_output_sequence'] as num?)?.toInt() ?? -1,
      (body['viewer_presence_epoch'] as num?)?.toInt() ?? -1,
    ].join(':');
    if (_lastReadySignaturesByTerminal[terminalId] == readySignature) {
      AppLogger.trace(
        '$_terminalStreamTraceTag ignore duplicate terminal ready terminalId=$terminalId',
      );
      return;
    }
    _lastReadySignaturesByTerminal[terminalId] = readySignature;

    final authority = _authorityCacheFor(terminalId);
    authority.protocolVersion = (body['protocol_version'] as num?)?.toInt() ?? 0;
    authority.syncMode = body['sync_mode'] as String?;
    final viewerPresenceEpoch = (body['viewer_presence_epoch'] as num?)?.toInt();
    if (viewerPresenceEpoch != null && viewerPresenceEpoch > 0) {
      _viewerPresenceEpochByTerminal[terminalId] = viewerPresenceEpoch;
    }
    final summary = _terminalSummaryFromEvent(body);
    final previousActiveId = state.activeTerminalId;
    final shouldAutoActivate = _shouldAutoActivateIncomingTerminal(summary);
    AppLogger.info(
      '$_terminalStreamTraceTag terminal ready terminalId=$terminalId title=${summary.title} source=${summary.source} activeBefore=${previousActiveId ?? '-'} autoActivate=$shouldAutoActivate',
    );
    _upsertTerminalSummary(summary);
    if (shouldAutoActivate && previousActiveId != terminalId) {
      Future<void>(() => attachTerminal(terminalId));
    }
  }

  @override
  void _replaceTerminals(List<TerminalSessionSummary> terminals) {
    final currentActive = state.activeTerminalId;
    final hasCurrent = currentActive != null &&
        terminals.any((terminal) => terminal.id == currentActive);
    _autoCreatedTerminalIds.removeWhere(
      (terminalId) => !terminals.any((terminal) => terminal.id == terminalId),
    );
    state = state.copyWith(
      terminals: terminals,
      pendingApprovalRequests: state.pendingApprovalRequests
          .where((request) => terminals.any((terminal) => terminal.id == request.terminalId))
          .toList(growable: false),
      activeTerminalId: hasCurrent ? currentActive : null,
      clearActiveTerminalId: !hasCurrent,
    );
    _pruneTerminalCache(terminals.map((terminal) => terminal.id));
  }

  String? _resolveTerminalToActivate(List<TerminalSessionSummary> terminals) {
    if (terminals.isEmpty) {
      return null;
    }

    final currentActive = state.activeTerminalId;
    if (currentActive != null &&
        terminals.any((terminal) => terminal.id == currentActive)) {
      return currentActive;
    }
    return terminals.first.id;
  }

  String? _resolveNextTerminalAfterClose({
    required String terminalId,
    required List<TerminalSessionSummary> terminalsBeforeClose,
    required List<TerminalSessionSummary> remaining,
  }) {
    if (remaining.isEmpty) {
      return null;
    }

    final closedIndex =
        terminalsBeforeClose.indexWhere((terminal) => terminal.id == terminalId);
    if (closedIndex < 0) {
      return remaining.first.id;
    }

    final nextIndex = closedIndex.clamp(0, remaining.length - 1).toInt();
    return remaining[nextIndex].id;
  }

  bool _shouldAutoActivateIncomingTerminal(TerminalSessionSummary incoming) {
    final activeTerminalId = state.activeTerminalId;
    if (activeTerminalId == null) {
      return true;
    }
    if (activeTerminalId == incoming.id) {
      return false;
    }
    if (!_autoCreatedTerminalIds.contains(activeTerminalId)) {
      return false;
    }
    if (_autoCreatedTerminalIds.contains(incoming.id)) {
      return false;
    }
    final incomingLooksInteractive = incoming.source == 'local_pty' ||
        incoming.title.toLowerCase().contains('sirix') ||
        incoming.shell.toLowerCase().contains('sirix') ||
        incoming.shell.toLowerCase().contains('codex');
    if (!incomingLooksInteractive) {
      return false;
    }
    AppLogger.info(
      '$_terminalStreamTraceTag auto activate incoming terminalId=${incoming.id} replacingPlaceholder=$activeTerminalId title=${incoming.title} shell=${incoming.shell}',
    );
    return true;
  }

  @override
  void _removeTerminalById(String terminalId) {
    final terminalsBeforeClose = state.terminals;
    final closingActive = state.activeTerminalId == terminalId;
    final remaining = terminalsBeforeClose
        .where((terminal) => terminal.id != terminalId)
        .toList(growable: false);
    final nextActiveId = closingActive
        ? _resolveNextTerminalAfterClose(
            terminalId: terminalId,
            terminalsBeforeClose: terminalsBeforeClose,
            remaining: remaining,
          )
        : state.activeTerminalId;
    final closedMessage =
        closingActive && nextActiveId == null ? '[terminal closed]' : null;
    state = state.copyWith(
      terminals: remaining,
      pendingApprovalRequests: state.pendingApprovalRequests
          .where((request) => request.terminalId != terminalId)
          .toList(growable: false),
      activeTerminalId: nextActiveId,
      errorMessage: closedMessage,
      clearActiveTerminalId: closingActive && nextActiveId == null,
    );
    _disposeCachedTerminal(terminalId);
  }

  Future<void> resolveApprovalRequest({
    required TerminalApprovalRequest request,
    required String decision,
    required String scope,
    String? prefix,
  }) async {
    final localClient = _desktopLocalClient;
    try {
      if (localClient != null) {
        await localClient.resolveAiApproval(
          sessionId: request.aiSessionId,
          requestId: request.requestId,
          capabilityKey: request.capabilityKey,
          agentId: request.agentId,
          decision: decision,
          scope: scope,
          prefix: prefix,
        );
      } else {
        await _apiClient.resolveAiApproval(
          accessToken: _config.accessToken,
          sessionId: request.aiSessionId,
          requestId: request.requestId,
          capabilityKey: request.capabilityKey,
          agentId: request.agentId,
          decision: decision,
          scope: scope,
          prefix: prefix,
        );
      }
      _removeApprovalRequest(
        requestId: request.requestId ?? '',
        aiSessionId: request.aiSessionId,
        agentId: request.agentId,
        capabilityKey: request.capabilityKey,
      );
      state = state.copyWith(clearError: true);
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Failed to resolve approval: $error',
      );
    }
  }

  @override
  void _removeApprovalRequest({
    required String? requestId,
    required String aiSessionId,
    String? agentId,
    required String capabilityKey,
  }) {
    final normalizedRequestId = requestId?.trim() ?? '';
    state = state.copyWith(
      pendingApprovalRequests: state.pendingApprovalRequests
          .where(
            (request) {
              if (normalizedRequestId.isNotEmpty &&
                  request.requestId != null &&
                  request.requestId == normalizedRequestId) {
                return false;
              }
              return !(request.aiSessionId == aiSessionId &&
                  (agentId == null || request.agentId == agentId) &&
                  request.capabilityKey == capabilityKey);
            },
          )
          .toList(growable: false),
    );
  }

  bool _shouldRetrySessionAttach(String terminalId) {
    final streamState = _terminalStreams[terminalId];
    if (streamState?.hasInteractiveFrame == true) {
      return false;
    }
    for (final terminal in state.terminals) {
      if (terminal.id == terminalId) {
        return terminal.state != 'active';
      }
    }
    return false;
  }

  Future<void> _retrySessionAttachUntilReady(String terminalId) async {
    for (var attempt = 0; attempt < _terminalSessionAttachRetryCount; attempt += 1) {
      await Future<void>.delayed(_terminalSessionAttachRetryDelay);
      if (_transport != _TerminalTransport.sessionWebrtc ||
          state.activeTerminalId != terminalId ||
          !_shouldUseSessionTransport ||
          !_shouldRetrySessionAttach(terminalId)) {
        return;
      }

      await _sessionTerminalChannelController.sendJson({
        'type': 'terminal.attach',
        'payload': {
          'terminal_id': terminalId,
          'protocol_version': 2,
          'sync_mode': _terminalSyncModeV2,
          'client_kind': 'mobile_app',
        },
      });
      await _sessionTerminalChannelController.sendJson({
        'type': 'terminal.bootstrap.request',
        'payload': {
          'terminal_id': terminalId,
        },
      });
    }
  }

  bool _shouldRetryDesktopLocalAttach(String terminalId) {
    if (_transport != _TerminalTransport.desktopLocal) {
      return false;
    }

    for (final terminal in state.terminals) {
      if (terminal.id == terminalId) {
        return terminal.state != 'active';
      }
    }
    return false;
  }

  Future<void> _retryDesktopLocalAttachUntilReady(String terminalId) async {
    for (var attempt = 0; attempt < _terminalSessionAttachRetryCount; attempt += 1) {
      await Future<void>.delayed(_terminalSessionAttachRetryDelay);
      if (_transport != _TerminalTransport.desktopLocal ||
          state.activeTerminalId != terminalId ||
          !_shouldUseDesktopLocalTransport ||
          !_shouldRetryDesktopLocalAttach(terminalId)) {
        return;
      }

      final channel = _channel;
      final localClient = _desktopLocalClient;
      if (channel == null || localClient == null) {
        return;
      }

      // Desktop terminal creation is async on the desktop-server side. The
      // backend can return an "opening" terminal record before the local PTY
      // has published its first ready/snapshot event, which leaves the client
      // stuck with a blank "OPENING" tab and no usable stdin path. Re-sending
      // attach asks desktop-server to replay terminal.ready + terminal.snapshot
      // once the PTY actually exists, without changing the underlying terminal
      // session or transport model.
      localClient.sendTerminalAttach(
        channel: channel,
        terminalId: terminalId,
      );
    }

    await _reconcileDesktopLocalTerminalList(activeTerminalIdHint: terminalId);
  }

  Future<void> _reconcileDesktopLocalTerminalList({
    String? activeTerminalIdHint,
  }) async {
    final localClient = _desktopLocalClient;
    if (localClient == null || !_shouldUseDesktopLocalTransport) {
      return;
    }

    await Future<void>.delayed(_desktopLocalAttachReconcileDelay);
    if (_disposed || _loadingInFlight) {
      return;
    }

    try {
      final terminals = await localClient.listTerminalSessions();
      _replaceTerminals(terminals);
      final requestedTerminalId = activeTerminalIdHint ?? state.activeTerminalId;
      if (requestedTerminalId == null || requestedTerminalId.isEmpty) {
        return;
      }

      final stillPresent = terminals.any((terminal) => terminal.id == requestedTerminalId);
      if (!stillPresent) {
        // Desktop-local creation can fail after the backend has already handed
        // the UI an optimistic "opening" record. Reconcile against the real
        // desktop-server session list so stale tabs disappear instead of
        // lingering as blank OPENING terminals.
        _removeTerminalById(requestedTerminalId);
        state = state.copyWith(
          errorMessage: AppLocalizations.current.terminalCreateUnavailable,
        );
      }
    } catch (error, stackTrace) {
      AppLogger.warn('desktop local terminal reconcile failed error=$error');
      AppLogger.warn('desktop local terminal reconcile stack: $stackTrace');
    }
  }

  @override
  void _updateTerminalStateById(String terminalId, String nextState) {
    _updateTerminalSummary(
      terminalId,
      (terminal) => terminal.copyWith(state: nextState),
    );
  }

  void _upsertTerminalSummary(TerminalSessionSummary incoming) {
    final existingIndex = state.terminals.indexWhere((terminal) => terminal.id == incoming.id);
    final next = [...state.terminals];
    if (existingIndex >= 0) {
      next[existingIndex] = incoming;
    } else {
      next.add(incoming);
    }
    next.sort((left, right) => left.createdAt.compareTo(right.createdAt));

    final currentActiveId = state.activeTerminalId;
    final hasCurrentActive = currentActiveId != null &&
        next.any((terminal) => terminal.id == currentActiveId);
    final fallbackActiveId = next.isEmpty ? null : next.first.id;
    state = state.copyWith(
      terminals: next,
      activeTerminalId: hasCurrentActive ? currentActiveId : fallbackActiveId,
      clearActiveTerminalId: next.isEmpty,
    );
  }

  @override
  void _updateTerminalSummary(
    String terminalId,
    TerminalSessionSummary Function(TerminalSessionSummary terminal) transform,
  ) {
    bool updated = false;
    final terminals = [
      for (final terminal in state.terminals)
        if (terminal.id == terminalId)
          () {
            updated = true;
            return transform(terminal);
          }()
        else
          terminal,
    ];

    if (!updated) {
      return;
    }

    state = state.copyWith(terminals: terminals);
  }

  @override
  TerminalSessionSummary _terminalSummaryFromEvent(Map<String, dynamic> json) {
    final createdAt = DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now();
    return TerminalSessionSummary(
      id: json['terminal_id'] as String? ?? json['id'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? _config.deviceId ?? '',
      title: json['title'] as String? ?? 'Terminal',
      source: json['source'] as String? ?? 'unknown',
      shell: json['shell'] as String? ?? 'default',
      cwd: json['cwd'] as String? ?? '~',
      state: json['state'] as String? ?? 'active',
      cols: (json['cols'] as num?)?.toInt() ?? 120,
      rows: (json['rows'] as num?)?.toInt() ?? 32,
      createdAt: createdAt,
      closedAt: json['closed_at'] == null
          ? null
          : DateTime.tryParse(json['closed_at'] as String? ?? ''),
    );
  }
}
