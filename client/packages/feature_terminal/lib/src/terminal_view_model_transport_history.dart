part of 'terminal_view_model.dart';

extension _TerminalViewModelTransportHistory on _TerminalViewModelTransportBase {
  Future<void> _requestTerminalHistoryRange({
    required String terminalId,
    required int startLine,
    required int endLine,
  }) async {
    if (startLine >= endLine) {
      AppLogger.info(
        '$_terminalStreamTraceTag skip history request terminalId=$terminalId reason=empty_range start=$startLine end=$endLine',
      );
      return;
    }
    final authority = _terminalAuthorities[terminalId];
    final generation = authority?.historyGeneration ?? 0;
    final rangeKey = _historyRangeKey(
      generation: generation,
      startLine: startLine,
      endLine: endLine,
    );
    final pendingKeys = _pendingHistoryRangesByTerminal.putIfAbsent(
      terminalId,
      () => <String>{},
    );
    if (!pendingKeys.add(rangeKey)) {
      AppLogger.info(
        '$_terminalStreamTraceTag skip duplicate history request terminalId=$terminalId generation=$generation start=$startLine end=$endLine',
      );
      return;
    }
    final requestId = 'history-${_historyRequestSequence++}';
    AppLogger.info(
      '$_terminalStreamTraceTag request history range terminalId=$terminalId requestId=$requestId generation=$generation start=$startLine end=$endLine transport=${_transport?.name ?? 'none'} cacheSize=${authority?.historyLines.length ?? 0}',
    );
    if (_transport == _TerminalTransport.sessionWebrtc) {
      final sent = await _sessionTerminalChannelController.sendJson(
        buildTerminalHistoryRangeRequestMessage(
          requestId: requestId,
          terminalId: terminalId,
          historyGeneration: generation,
          startLine: startLine,
          endLine: endLine,
        ),
      );
      if (!sent) {
        pendingKeys.remove(rangeKey);
      }
      return;
    }

    final channel = _channel;
    if (_transport == _TerminalTransport.desktopLocal) {
      if (channel == null) {
        pendingKeys.remove(rangeKey);
        return;
      }
      _desktopLocalClient?.sendTerminalHistoryRangeRequest(
        channel: channel,
        requestId: requestId,
        terminalId: terminalId,
        historyGeneration: generation,
        startLine: startLine,
        endLine: endLine,
      );
      return;
    }

    if (channel == null) {
      pendingKeys.remove(rangeKey);
      return;
    }
    channel.sink.add(
      jsonEncode(
        buildTerminalHistoryRangeRequestMessage(
          requestId: requestId,
          terminalId: terminalId,
          historyGeneration: generation,
          startLine: startLine,
          endLine: endLine,
        ),
      ),
    );
  }

  void _handleTerminalVerticalScroll({
    required String terminalId,
    required double extentBefore,
  }) {
    if (extentBefore > 96) {
      return;
    }
    final authority = _terminalAuthorities[terminalId];
    if (authority == null) {
      return;
    }
    final oldestCachedLine = authority.oldestCachedLine;
    if (oldestCachedLine == null) {
      return;
    }
    final remaining = oldestCachedLine - authority.historyStartLine;
    if (remaining <= 0 || remaining >= 200) {
      return;
    }
    final nextStartLine = (oldestCachedLine - 200).clamp(
      authority.historyStartLine,
      oldestCachedLine,
    );
    if (nextStartLine >= oldestCachedLine) {
      return;
    }
    unawaited(
      _requestTerminalHistoryRange(
        terminalId: terminalId,
        startLine: nextStartLine,
        endLine: oldestCachedLine,
      ),
    );
  }

  String _historyRangeKey({
    required int generation,
    required int startLine,
    required int endLine,
  }) {
    return '$generation:$startLine:$endLine';
  }

  void _forgetPendingHistoryRange({
    required String terminalId,
    required int generation,
    required int? startLine,
    required int? endLine,
  }) {
    if (startLine == null || endLine == null) {
      return;
    }
    final pending = _pendingHistoryRangesByTerminal[terminalId];
    if (pending == null) {
      return;
    }
    pending.remove(
      _historyRangeKey(
        generation: generation,
        startLine: startLine,
        endLine: endLine,
      ),
    );
    if (pending.isEmpty) {
      _pendingHistoryRangesByTerminal.remove(terminalId);
    }
  }

  String _screenSnapshotSignature({
    required Map<String, dynamic> body,
    required int rows,
    required int cols,
  }) {
    final screenData = body['screen_data_base64'] as String?;
    if (screenData != null && screenData.isNotEmpty) {
      return 'b64:${screenData.length}:${screenData.hashCode}';
    }

    final cursorRow = (body['cursor_row'] as num?)?.toInt() ?? 0;
    final cursorCol = (body['cursor_col'] as num?)?.toInt() ?? 0;
    final lineHashes = (body['screen_lines'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (line) => Object.hash(
            line['text'],
            line['wrapped'],
            line['hard_break'],
          ),
        );
    return 'lines:$rows:$cols:$cursorRow:$cursorCol:${Object.hashAll(lineHashes)}';
  }

  void _scheduleTerminalViewportSummaryUpdate({
    required String terminalId,
    required int cols,
    required int rows,
  }) {
    TerminalSessionSummary? current;
    for (final terminal in state.terminals) {
      if (terminal.id == terminalId) {
        current = terminal;
        break;
      }
    }
    if (current == null || (current.cols == cols && current.rows == rows)) {
      return;
    }

    // Terminal.onResize can fire from RenderTerminal.performLayout. Riverpod
    // forbids state mutation while widgets are building, so we defer only the
    // summary write while keeping the PTY resize transport immediate.
    Future<void>(() {
      _updateTerminalSummary(
        terminalId,
        (terminal) => terminal.copyWith(cols: cols, rows: rows),
      );
    });
  }

  Future<WebSocketChannel> _connectDesktopLocalChannel() async {
    if (_channel != null && _transport == _TerminalTransport.desktopLocal) {
      return _channel!;
    }
    final inFlight = _desktopLocalChannelConnectFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final localClient = _desktopLocalClient;
    if (localClient == null) {
      throw StateError('desktop local client unavailable');
    }

    final connectFuture = () async {
      final channel = await localClient.connect();
      _channel = channel;
      _transport = _TerminalTransport.desktopLocal;
      _channelSubscription = channel.stream.listen(
        (raw) => _handleSocketEvent(channel, raw),
        onError: (Object error, StackTrace stackTrace) {
          if (!identical(_channel, channel)) {
            return;
          }
          _channel = null;
          _transport = null;
          _desktopLocalChannelConnectFuture = null;
          state = state.copyWith(
            connecting: false,
            errorMessage: AppLocalizations.current.terminalStreamError('$error'),
          );
        },
        onDone: () {
          if (!identical(_channel, channel)) {
            return;
          }
          _channel = null;
          _transport = null;
          _desktopLocalChannelConnectFuture = null;
          state = state.copyWith(connecting: false);
        },
      );
      return channel;
    }();
    _desktopLocalChannelConnectFuture = connectFuture;
    try {
      return await connectFuture;
    } finally {
      // 这里只清理“连接中的 Future”，不清理真正已建立的 channel。
      // 这样可以防止并发 attach/list/close 各自调用 connect() 时重复建立
      // 多条 desktop local websocket；日志里的多次
      // `desktop local ws connected` 就是这种重入迹象。
      if (identical(_desktopLocalChannelConnectFuture, connectFuture)) {
        _desktopLocalChannelConnectFuture = null;
      }
    }
  }
}
