part of 'terminal_view_model.dart';

abstract class _TerminalViewModelEventsABase extends _TerminalViewModelRuntimeBase {
  _TerminalViewModelEventsABase({
    required super.apiClient,
    required super.eventClient,
    required super.desktopLocalClient,
    required super.sessionTerminalChannelController,
    required super.config,
  });

  void _handleTerminalReady(Map<String, dynamic> body);
  List<int>? _decodeEventBytes(Map<String, dynamic> body);
  int? _resolveEventStreamSequence(Map<String, dynamic> body);
  TerminalSessionSummary _terminalSummaryFromEvent(Map<String, dynamic> json);
  void _replaceTerminals(List<TerminalSessionSummary> terminals);
  void _removeTerminalById(String terminalId);
  void _updateTerminalStateById(String terminalId, String nextState);
  List<int>? _decodeScreenSnapshotBytes(Map<String, dynamic> body);
  void _removeApprovalRequest({
    required String aiSessionId,
    required String? requestId,
    required String capabilityKey,
    String? agentId,
  });

  @override
  Future<void> _detachChannel() async {
    _flushPendingOutboundOperations();

    final activeTerminalId = state.activeTerminalId;
    final viewerPresenceEpoch = activeTerminalId == null
        ? null
        : _viewerPresenceEpochByTerminal[activeTerminalId];

    if (_transport == _TerminalTransport.sessionWebrtc) {
      if (activeTerminalId != null) {
        unawaited(
          _sessionTerminalChannelController.sendJson(
            buildTerminalDetachMessage(
              terminalId: activeTerminalId,
              clientKind: 'mobile_app',
              viewerPresenceEpoch: viewerPresenceEpoch,
            ),
          ),
        );
      }
      _transport = null;
      _attachingTerminalId = null;
      return;
    }

    final channel = _channel;
    final subscription = _channelSubscription;
    _channel = null;
    _transport = null;
    _channelSubscription = null;
    _desktopLocalChannelConnectFuture = null;
    _attachingTerminalId = null;
    if (channel != null &&
        activeTerminalId != null &&
        _desktopLocalClient != null) {
      _desktopLocalClient.sendTerminalDetach(
        channel: channel,
        terminalId: activeTerminalId,
        clientKind: 'desktop_app',
        viewerPresenceEpoch: viewerPresenceEpoch,
      );
    }
    await subscription?.cancel();
    await channel?.sink.close();
  }

  void _flushPendingOutboundOperations() {
    _flushPendingInput();
    _flushPendingResize();
    _inputTimer?.cancel();
    _inputTimer = null;
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _resizeTrailingWindowActive = false;
    for (final timer in _pendingAuthorityRefreshTimers.values) {
      timer.cancel();
    }
    _pendingAuthorityRefreshTimers.clear();
    _pendingAuthorityRefreshes.clear();
  }

  @override
  void _handleSocketEvent(WebSocketChannel channel, dynamic raw) {
    if (!identical(_channel, channel)) {
      return;
    }

    final payload = BackendEventClient.decodeEvent(raw);
    if (payload == null) {
      return;
    }

    _handleTerminalEventPayload(payload);
  }

  @override
  void _handleSessionChannelEvent(Map<String, dynamic> payload) {
    if (!_shouldUseSessionTransport) {
      return;
    }

    final type = payload['type'] as String?;
    final shouldProcessWithoutSessionTransport = type == 'terminal.list' ||
        type == 'terminal.ready' ||
        type == 'terminal.closed' ||
        type == 'terminal.error';
    if (_transport != _TerminalTransport.sessionWebrtc &&
        !shouldProcessWithoutSessionTransport) {
      return;
    }

    _handleTerminalEventPayload(payload);
  }

  void _handleTerminalEventPayload(Map<String, dynamic> payload) {
    final type = payload['type'] as String?;
    final body = payload['payload'] as Map<String, dynamic>?;
    if (type == null || body == null) {
      return;
    }

    switch (type) {
      case 'terminal.list':
        _handleTerminalList(body);
        break;
      case 'terminal.ready':
        _handleTerminalReady(body);
        break;
      case 'terminal.state.snapshot':
        _handleTerminalStateSnapshot(body);
        break;
      case 'terminal.screen.snapshot':
        _handleTerminalScreenSnapshot(body);
        break;
      case 'terminal.history.append':
        _handleTerminalHistoryAppend(body);
        break;
      case 'terminal.layout.changed':
        _handleTerminalLayoutChanged(body);
        break;
      case 'terminal.geometry.changed':
        _handleTerminalGeometryChanged(body);
        break;
      case 'terminal.buffer.changed':
        _handleTerminalBufferChanged(body);
        break;
      case 'terminal.scrollback.trimmed':
        _handleTerminalScrollbackTrimmed(body);
        break;
      case 'terminal.history.range.response':
        _handleTerminalHistoryRangeResponse(body);
        break;
      case 'terminal.history.range.error':
        _handleTerminalHistoryRangeError(body);
        break;
      case 'terminal.history.invalidated':
        _handleTerminalHistoryInvalidated(body);
        break;
      case 'terminal.snapshot':
        _handleTerminalSnapshot(body);
        break;
      case 'terminal.output':
        _handleTerminalOutput(body);
        break;
      case 'terminal.closed':
        _handleTerminalClosed(body);
        break;
      case 'terminal.error':
        _handleTerminalError(body);
        break;
      case 'ai.approval.request':
        _handleApprovalRequest(body);
        break;
      case 'ai.approval.resolved':
        _handleApprovalResolved(body);
        break;
      default:
        break;
    }
  }

  void _handleTerminalOutput(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    final bytes = _decodeEventBytes(body);
    final streamSequence = _resolveEventStreamSequence(body);
    if (terminalId == null || bytes == null) {
      return;
    }

    final authority = _terminalAuthorities[terminalId];
    if (authority?.isV2Authority == true) {
      AppLogger.info(
        '$_terminalStreamTraceTag ignore raw output on v2 authority terminalId=$terminalId sequence=${streamSequence ?? -1}',
      );
      return;
    }

    final streamState = _streamStateFor(terminalId);
    if (streamSequence != null &&
        streamState.lastAppliedSequence != null &&
        streamSequence <= streamState.lastAppliedSequence!) {
      AppLogger.info(
        '$_terminalStreamTraceTag ignore stale output terminalId=$terminalId sequence=$streamSequence lastApplied=${streamState.lastAppliedSequence}',
      );
      return;
    }

    final text = streamState.decode(bytes);
    if (text.isNotEmpty) {
      terminalFor(terminalId)?.write(text);
    }
    streamState.lastAppliedSequence = streamSequence ?? streamState.lastAppliedSequence;
    streamState.markInteractiveFrame();
  }

  void _handleTerminalList(Map<String, dynamic> body) {
    final rawTerminals = body['terminals'] as List<dynamic>? ?? const [];
    final terminals = rawTerminals
        .whereType<Map<String, dynamic>>()
        .map(_terminalSummaryFromEvent)
        .toList(growable: false);
    _replaceTerminals(terminals);
    final completer = _pendingSessionTerminalListCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(terminals);
    }
    _pendingSessionTerminalListCompleter = null;
  }

  void _handleTerminalSnapshot(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    final bytes = _decodeEventBytes(body);
    final streamSequence = _resolveEventStreamSequence(body);
    if (terminalId == null) {
      return;
    }
    final authority = _terminalAuthorities[terminalId];
    if (authority?.isV2Authority == true) {
      // Shared terminal v2 has switched to an authority bootstrap
      // (`terminal.ready` + state/screen/history preview). If an old relay or
      // stale sender still emits a raw replay snapshot after v2 is negotiated,
      // applying that snapshot would reintroduce the duplicate/overlap problem
      // we are explicitly removing from the tmux-aligned architecture.
      AppLogger.info(
        '$_terminalStreamTraceTag ignore raw snapshot on v2 authority terminalId=$terminalId sequence=${streamSequence ?? -1}',
      );
      return;
    }
    final historyTruncated = body['history_truncated'] == true;
    if (historyTruncated) {
      // A truncated replay is intentionally treated as degraded history instead
      // of a trustworthy screen baseline. Waiting for live output is safer
      // than replaying a partial control sequence and corrupting cursor state.
      AppLogger.warn(
        '$_terminalStreamTraceTag skip truncated snapshot terminalId=$terminalId sequence=${streamSequence ?? -1}',
      );
      return;
    }

    _replaceTerminalSnapshot(
      terminalId: terminalId,
      bytes: bytes ?? const <int>[],
      streamSequence: streamSequence,
      source: 'output',
    );
    _streamStateFor(terminalId).markInteractiveFrame();
  }

  void _handleTerminalClosed(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }

    _removeTerminalById(terminalId);
  }

  void _handleTerminalError(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }

    final message = body['error_message'] as String? ?? 'unknown';
    _updateTerminalStateById(terminalId, 'error');
    if (terminalId == state.activeTerminalId) {
      state = state.copyWith(
        errorMessage: AppLocalizations.current.terminalStreamError(message),
      );
    }
    terminalFor(terminalId)?.write('\r\n[terminal error] $message\r\n');
  }

  void _handleTerminalStateSnapshot(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    final authority = _authorityCacheFor(terminalId);
    authority.applyStateSnapshot(body);
    if (authority.isV2Authority) {
      _scheduleAuthorityRefresh(
        terminalId,
        reason: 'state_snapshot',
      );
    }
  }

  void _handleTerminalScreenSnapshot(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    final authority = _authorityCacheFor(terminalId);
    authority.applyScreenSnapshot(body);
    if (!authority.isV2Authority) {
      final screenBytes = _decodeScreenSnapshotBytes(body);
      if (screenBytes != null) {
        _replaceTerminalSnapshot(
          terminalId: terminalId,
          bytes: screenBytes,
          streamSequence: null,
          source: 'screen',
        );
      }
      return;
    }
    final streamState = _streamStateFor(terminalId);
    final snapshotSignature = _screenSnapshotSignature(
      body: body,
      rows: authority.rows,
      cols: authority.cols,
    );
    if (streamState.isDuplicateScreenSnapshot(
      signature: snapshotSignature,
      bufferEpoch: authority.bufferEpoch,
      layoutEpoch: authority.layoutEpoch,
      rows: authority.rows,
      cols: authority.cols,
    )) {
      streamState.markInteractiveFrame();
      AppLogger.trace(
        '$_terminalStreamTraceTag ignore duplicate screen snapshot terminalId=$terminalId bufferEpoch=${authority.bufferEpoch} layoutEpoch=${authority.layoutEpoch} rows=${authority.rows} cols=${authority.cols}',
      );
      return;
    }
    streamState.markAppliedScreenSnapshot(
      signature: snapshotSignature,
      bufferEpoch: authority.bufferEpoch,
      layoutEpoch: authority.layoutEpoch,
      rows: authority.rows,
      cols: authority.cols,
    );
    streamState.markInteractiveFrame();
    _scheduleAuthorityRefresh(
      terminalId,
      reason: 'screen_snapshot',
    );
  }

  void _handleTerminalHistoryAppend(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    final authority = _authorityCacheFor(terminalId);
    authority.appendHistory(body);
    if (authority.isV2Authority) {
      _scheduleAuthorityRefresh(
        terminalId,
        reason: 'history_append',
      );
    }
  }

  void _handleTerminalLayoutChanged(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    final authority = _authorityCacheFor(terminalId);
    authority.applyLayoutChanged(body);
    _scheduleTerminalViewportSummaryUpdate(
      terminalId: terminalId,
      cols: authority.cols,
      rows: authority.rows,
    );
    if (authority.isV2Authority) {
      _scheduleAuthorityRefresh(
        terminalId,
        reason: 'layout_changed',
      );
    }
  }

  void _handleTerminalGeometryChanged(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    final authority = _authorityCacheFor(terminalId);
    authority.applyGeometryChanged(body);
    _scheduleTerminalViewportSummaryUpdate(
      terminalId: terminalId,
      cols: authority.cols,
      rows: authority.rows,
    );
    if (authority.isV2Authority) {
      _scheduleAuthorityRefresh(
        terminalId,
        reason: 'geometry_changed',
      );
    }
  }

  void _handleTerminalBufferChanged(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    final authority = _authorityCacheFor(terminalId);
    authority.applyBufferChanged(body);
    if (authority.isV2Authority) {
      _scheduleAuthorityRefresh(
        terminalId,
        reason: 'buffer_changed',
      );
    }
  }

  void _handleTerminalScrollbackTrimmed(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    final authority = _authorityCacheFor(terminalId);
    authority.applyTrimmed(body);
    if (authority.isV2Authority) {
      _scheduleAuthorityRefresh(
        terminalId,
        reason: 'scrollback_trimmed',
      );
    }
  }

  void _handleTerminalHistoryRangeResponse(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    AppLogger.info(
      '$_terminalStreamTraceTag history range response terminalId=$terminalId generation=${(body['history_generation'] as num?)?.toInt() ?? 0} start=${(body['start_line'] as num?)?.toInt()} end=${(body['end_line'] as num?)?.toInt()} lines=${(body['lines'] as List<dynamic>?)?.length ?? 0}',
    );
    _forgetPendingHistoryRange(
      terminalId: terminalId,
      generation: (body['history_generation'] as num?)?.toInt() ?? 0,
      startLine: (body['start_line'] as num?)?.toInt(),
      endLine: (body['end_line'] as num?)?.toInt(),
    );
    final authority = _authorityCacheFor(terminalId);
    authority.applyHistoryRangeResponse(body);
    AppLogger.info(
      '$_terminalStreamTraceTag history cache updated terminalId=$terminalId cacheSize=${authority.historyLines.length} oldest=${authority.oldestCachedLine} newest=${authority.historyLines.isEmpty ? null : (authority.historyLines.keys.toList()..sort()).last}',
    );
    _scheduleAuthorityRefresh(
      terminalId,
      reason: 'history_range_response',
    );
  }

  void _handleTerminalHistoryRangeError(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    final code = body['code'] as String? ?? 'unknown';
    if (terminalId == null) {
      return;
    }
    AppLogger.warn(
      '$_terminalStreamTraceTag history range error terminalId=$terminalId code=$code generation=${(body['history_generation'] as num?)?.toInt() ?? 0} start=${(body['start_line'] as num?)?.toInt()} end=${(body['end_line'] as num?)?.toInt()} message=${body['message']}',
    );
    _forgetPendingHistoryRange(
      terminalId: terminalId,
      generation: (body['history_generation'] as num?)?.toInt() ?? 0,
      startLine: (body['start_line'] as num?)?.toInt(),
      endLine: (body['end_line'] as num?)?.toInt(),
    );
    AppLogger.warn('$_terminalStreamTraceTag history range error terminalId=$terminalId code=$code');
  }

  void _handleTerminalHistoryInvalidated(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    _pendingHistoryRangesByTerminal.remove(terminalId);
    final authority = _authorityCacheFor(terminalId);
    if (authority.isDuplicateHistoryInvalidation(body)) {
      AppLogger.trace(
        '$_terminalStreamTraceTag ignore duplicate history invalidated terminalId=$terminalId generation=${(body['history_generation'] as num?)?.toInt() ?? 0} start=${(body['start_line'] as num?)?.toInt()} end=${(body['end_line'] as num?)?.toInt()}',
      );
      return;
    }
    authority.applyHistoryInvalidated(body);
    final previewStartLine = (body['start_line'] as num?)?.toInt() ?? authority.historyStartLine;
    final previewEndLine = (body['end_line'] as num?)?.toInt() ?? authority.historyEndLine;
    final previewLineCount =
        (previewEndLine - previewStartLine).clamp(0, _terminalAuthorityCacheMaxLines);
    final desiredBackfillLines =
        (_terminalAuthorityCacheMaxLines - previewLineCount).clamp(0, _terminalHistoryPrefetchChunkLines);
    final desiredStartLine =
        (previewStartLine - desiredBackfillLines).clamp(authority.historyStartLine, previewStartLine);
    final cacheSize = authority.historyLines.length;
    AppLogger.info(
      '$_terminalStreamTraceTag history invalidated terminalId=$terminalId generation=${authority.historyGeneration} history=${authority.historyStartLine}-${authority.historyEndLine} preview=$previewStartLine-$previewEndLine previewLines=$previewLineCount desiredStart=$desiredStartLine desiredBackfillLines=$desiredBackfillLines cacheSize=$cacheSize',
    );
    _scheduleAuthorityRefresh(
      terminalId,
      reason: 'history_invalidated_preview',
    );
    if (previewStartLine > desiredStartLine) {
      unawaited(
        _requestTerminalHistoryRange(
          terminalId: terminalId,
          startLine: desiredStartLine,
          endLine: previewStartLine,
        ),
      );
    }
  }

  String? _resolveEventTerminalId(Map<String, dynamic> body) {
    return body['terminal_id'] as String? ?? state.activeTerminalId;
  }
}
