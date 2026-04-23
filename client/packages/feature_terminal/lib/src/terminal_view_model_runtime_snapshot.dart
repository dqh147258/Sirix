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

  bool _rebuildTerminalFromAuthorityHistory(
    String terminalId, {
    required String reason,
  }) {
    final authority = _terminalAuthorities[terminalId];
    if (authority == null) {
      return false;
    }
    final terminal = terminalFor(terminalId);
    if (terminal == null) {
      return false;
    }
    final streamState = _streamStateFor(terminalId);
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
