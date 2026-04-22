part of 'terminal_view_model.dart';

extension _TerminalViewModelRuntimeSnapshot on _TerminalViewModelRuntimeBase {
  void _replaceTerminalSnapshot({
    required String terminalId,
    required List<int> bytes,
    required int? streamSequence,
    required String source,
  }) {
    final terminal = terminalFor(terminalId) ?? _createTerminal(terminalId);
    final streamState = _streamStateFor(terminalId);
    if (streamSequence != null &&
        streamState.lastAppliedSequence != null &&
        streamSequence < streamState.lastAppliedSequence!) {
      AppLogger.info(
        '$_terminalStreamTraceTag ignore stale snapshot terminalId=$terminalId sequence=$streamSequence lastApplied=${streamState.lastAppliedSequence}',
      );
      return;
    }

    _runWithSnapshotApplyGuard(terminalId, () {
      _applyAuthorityViewportIfNeeded(terminalId, terminal);
      _resetTerminalSnapshot(terminal);
      streamState.resetDecoder();
      final text = streamState.decode(bytes, replaceStreamState: true);
      if (text.isNotEmpty) {
        terminal.write(text);
      } else {
        terminal.notifyListeners();
      }
    });
    streamState.lastAppliedSequence = streamSequence;
    AppLogger.info(
      '$_terminalStreamTraceTag applied $source snapshot terminalId=$terminalId sequence=${streamSequence ?? -1} bytes=${bytes.length}',
    );
  }

  void _replaceTerminalScreenSnapshot({
    required String terminalId,
    required List<TerminalAuthorityLine> screenLines,
    required int cursorRow,
    required int cursorCol,
  }) {
    final terminal = terminalFor(terminalId) ?? _createTerminal(terminalId);
    final streamState = _streamStateFor(terminalId);
    final viewerRows = _preferredViewportRowsForTerminal(terminalId);
    final lockedTopOffset = streamState.initialVisibleWindowTopOffset;
    final visibleWindow = TerminalVisibleWindowPlanner.plan(
      screenLines: screenLines,
      cursorRow: cursorRow,
      cursorCol: cursorCol,
      viewerRows: viewerRows,
      lockedTopOffset: lockedTopOffset,
    );
    if (streamState.initialVisibleWindowTopOffset == null) {
      streamState.initialVisibleWindowTopOffset = visibleWindow.topOffset;
      AppLogger.info(
        '$_terminalStreamTraceTag lock initial visible window terminalId=$terminalId topOffset=${visibleWindow.topOffset} viewerRows=$viewerRows trailingBlankLines=${visibleWindow.trailingBlankLines}',
      );
    }
    final buffer = StringBuffer();
    for (var index = 0; index < visibleWindow.lines.length; index += 1) {
      buffer.write(visibleWindow.lines[index].text);
      if (index < visibleWindow.lines.length - 1) {
        buffer.write('\r\n');
      }
    }
    buffer.write('\x1b[${visibleWindow.cursorRow + 1};${visibleWindow.cursorCol + 1}H');

    _runWithSnapshotApplyGuard(terminalId, () {
      _applyAuthorityViewportIfNeeded(
        terminalId,
        terminal,
        visibleRowOverride: visibleWindow.lines.isEmpty ? null : visibleWindow.lines.length,
      );
      _resetTerminalSnapshot(terminal);
      streamState.resetDecoder();
      terminal.write(buffer.toString());
    });
    AppLogger.info(
      '$_terminalStreamTraceTag applied line snapshot terminalId=$terminalId rows=${visibleWindow.lines.length} cursor=${visibleWindow.cursorRow}:${visibleWindow.cursorCol} topOffset=${visibleWindow.topOffset} lockedTopOffset=${streamState.initialVisibleWindowTopOffset} trailingBlankLines=${visibleWindow.trailingBlankLines} viewerRows=$viewerRows',
    );
  }



  void _flushVisibleScreenSnapshotApply(String terminalId) {
    _pendingVisibleSnapshotTimers.remove(terminalId)?.cancel();
    final pending = _pendingVisibleSnapshotApplies.remove(terminalId);
    if (pending == null) {
      return;
    }
    final authority = _terminalAuthorities[terminalId];
    if (authority == null) {
      return;
    }
    final streamState = _streamStateFor(terminalId);
    if (streamState.isDuplicateScreenSnapshot(
      signature: pending.signature,
      bufferEpoch: authority.bufferEpoch,
      layoutEpoch: authority.layoutEpoch,
      rows: authority.rows,
      cols: authority.cols,
    )) {
      AppLogger.trace(
        '$_terminalStreamTraceTag skip flushed duplicate visible snapshot terminalId=$terminalId reason=${pending.reason} bufferEpoch=${pending.bufferEpoch} layoutEpoch=${pending.layoutEpoch}',
      );
      return;
    }
    AppLogger.info(
      '$_terminalStreamTraceTag flush visible snapshot apply terminalId=$terminalId reason=${pending.reason} bufferEpoch=${pending.bufferEpoch} layoutEpoch=${pending.layoutEpoch}',
    );
    _applyVisibleScreenSnapshot(
      terminalId: terminalId,
      body: pending.body,
      authority: authority,
    );
  }

  void _applyVisibleScreenSnapshot({
    required String terminalId,
    required Map<String, dynamic> body,
    required TerminalAuthorityCache authority,
  }) {
    final screenLines = (body['screen_lines'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TerminalAuthorityLine.fromJson)
        .toList(growable: false);
    final screenBytes = _decodeScreenSnapshotBytes(body);
    final terminal = terminalFor(terminalId);
    if (terminal != null) {
      final localScrollbackLines = terminal.mainBuffer.lines.length;
      if (localScrollbackLines > authority.rows) {
        // 对于已经累积出本地 scrollback 的共享终端，resize 期间继续用
        // “当前屏幕快照”整屏 replace 会把已有历史直接清掉，表现为一拖动
        // 就丢历史。此时仅同步 authority 几何，让 xterm 自己保留并重排
        // 已有缓冲区，比强制 replace 更稳定。
        AppLogger.info(
          '$_terminalStreamTraceTag skip visible snapshot replace terminalId=$terminalId because=preserve_local_scrollback localLines=$localScrollbackLines authorityRows=${authority.rows}',
        );
        _runWithSnapshotApplyGuard(terminalId, () {
          _applyAuthorityViewportIfNeeded(terminalId, terminal);
        });
        return;
      }
    }
    if (screenLines.isNotEmpty &&
        TerminalVisibleWindowPlanner.hasMeaningfulVisibleText(screenLines)) {
      _replaceTerminalScreenSnapshot(
        terminalId: terminalId,
        screenLines: screenLines,
        cursorRow: (body['cursor_row'] as num?)?.toInt() ?? 0,
        cursorCol: (body['cursor_col'] as num?)?.toInt() ?? 0,
      );
      return;
    }
    if (screenBytes != null) {
      _replaceTerminalSnapshot(
        terminalId: terminalId,
        bytes: screenBytes,
        streamSequence: null,
        source: 'screen',
      );
      return;
    }
  }

  bool _rebuildTerminalFromAuthorityHistory(
    String terminalId, {
    required String reason,
  }) {
    final authority = _terminalAuthorities[terminalId];
    if (authority == null || authority.activeBuffer != 'main' || authority.historyLines.isEmpty) {
      return false;
    }
    if (authority.shouldPreferScreenSnapshotResync) {
      AppLogger.info(
        '$_terminalStreamTraceTag skip authority history rebuild terminalId=$terminalId reason=$reason because=visible_history_only',
      );
      return false;
    }
    final terminal = terminalFor(terminalId);
    if (terminal == null) {
      return false;
    }
    final streamState = _streamStateFor(terminalId);
    final localScrollbackLines = terminal.mainBuffer.lines.length;
    final authorityComparableLines = <int>[
      authority.rows,
      authority.cachedHistoryLineCount,
    ].fold(0, (maxValue, value) => value > maxValue ? value : maxValue);
    if (streamState.hasInteractiveFrame &&
        authorityComparableLines > 0 &&
        localScrollbackLines > authorityComparableLines) {
      // 已知遗留问题：系统 Terminal 持续拖动窗口时，Sirix shared terminal
      // 的历史仍可能出现错位/丢失；这里先明确保留本地 scrollback，避免
      // 当前轮次继续把问题扩大。后续需要更接近 tmux grid/reflow 的方案。
      //
      // 拖动窗口后的高频 geometry/history invalidation 期间，若终端已经在
      // Flutter 本地积累出足够 scrollback，再用 authority transcript
      // 整屏重建会把 xterm 当前缓冲区全部冲掉，表现为历史“跳变/塌缩”。
      // 这里改成优先保留已有本地缓冲，只在首帧/bootstrap 类场景允许整屏
      // rebuild，把 resize 稳定性放在首位。
      //
      // 这里额外参考 tmux 的思路：tmux 的 pane/grid 会把 scrollback 当成
      // 持久主数据，而不是把“当前可见行数”误当成完整历史。当前 Sirix
      // 还没有完整 grid/reflow 内核，因此至少要避免拿一个明显更“贫瘠”的
      // authority preview 去覆盖本地已存在的更多历史。
      AppLogger.info(
        '$_terminalStreamTraceTag skip authority history rebuild terminalId=$terminalId reason=$reason because=preserve_local_scrollback localLines=$localScrollbackLines authorityComparableLines=$authorityComparableLines authorityRows=${authority.rows} cachedLines=${authority.cachedHistoryLineCount}',
      );
      return false;
    }
    final transcript = authority.buildTranscript();
    if (transcript.isEmpty) {
      return false;
    }
    _runWithSnapshotApplyGuard(terminalId, () {
      _applyAuthorityViewportIfNeeded(terminalId, terminal);
      _resetTerminalSnapshot(terminal);
      streamState.resetDecoder();
      terminal.write(transcript);
    });
    AppLogger.info(
      '$_terminalStreamTraceTag rebuild authority history terminalId=$terminalId reason=$reason cachedLines=${authority.historyLines.length} transcriptBytes=${transcript.length}',
    );
    return true;
  }

  void _runWithSnapshotApplyGuard(String terminalId, VoidCallback action) {
    _snapshotApplyingTerminals.add(terminalId);
    try {
      action();
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _snapshotApplyingTerminals.remove(terminalId);
      });
    }
  }
}
