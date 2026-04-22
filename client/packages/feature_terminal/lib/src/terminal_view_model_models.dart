part of 'terminal_view_model.dart';

@immutable
class _PendingAuthorityRefresh {
  const _PendingAuthorityRefresh({
    required this.reason,
    required this.generation,
    required this.layoutEpoch,
    required this.bufferEpoch,
  });

  final String reason;
  final int generation;
  final int layoutEpoch;
  final int bufferEpoch;
}

@immutable
class _PendingScreenSnapshotApply {
  const _PendingScreenSnapshotApply({
    required this.reason,
    required this.body,
    required this.signature,
    required this.bufferEpoch,
    required this.layoutEpoch,
  });

  final String reason;
  final Map<String, dynamic> body;
  final String signature;
  final int bufferEpoch;
  final int layoutEpoch;
}

@immutable
class _QueuedResize {
  const _QueuedResize({
    required this.terminalId,
    required this.cols,
    required this.rows,
  });

  final String terminalId;
  final int cols;
  final int rows;
}

@immutable
class _TerminalViewportSize {
  const _TerminalViewportSize({
    required this.cols,
    required this.rows,
  });

  final int cols;
  final int rows;
}

class _QueuedInput {
  _QueuedInput({required this.terminalId});

  final String terminalId;
  final StringBuffer buffer = StringBuffer();
}

class TerminalStreamState {
  int? lastAppliedSequence;
  bool hasInteractiveFrame = false;
  bool awaitingViewportBootstrap = true;
  int? initialVisibleWindowTopOffset;
  String? _lastScreenSnapshotSignature;
  int? _lastScreenBufferEpoch;
  int? _lastScreenLayoutEpoch;
  int? _lastScreenRows;
  int? _lastScreenCols;
  final List<int> _pendingUtf8Bytes = <int>[];

  void prepareForAttach() {
    hasInteractiveFrame = false;
    awaitingViewportBootstrap = true;
    initialVisibleWindowTopOffset = null;
    _lastScreenSnapshotSignature = null;
    _lastScreenBufferEpoch = null;
    _lastScreenLayoutEpoch = null;
    _lastScreenRows = null;
    _lastScreenCols = null;
  }

  void markInteractiveFrame() {
    hasInteractiveFrame = true;
  }

  bool get acceptsViewportResync => awaitingViewportBootstrap || !hasInteractiveFrame;

  bool shouldForceViewportResync({
    required int bufferEpoch,
    required int layoutEpoch,
  }) {
    if (!hasInteractiveFrame) {
      return false;
    }
    final lastBufferEpoch = _lastScreenBufferEpoch;
    final lastLayoutEpoch = _lastScreenLayoutEpoch;
    if (lastBufferEpoch == null || lastLayoutEpoch == null) {
      return false;
    }
    return lastBufferEpoch != bufferEpoch || lastLayoutEpoch != layoutEpoch;
  }

  void resetDecoder() {
    _pendingUtf8Bytes.clear();
  }

  bool isDuplicateScreenSnapshot({
    required String signature,
    required int bufferEpoch,
    required int layoutEpoch,
    required int rows,
    required int cols,
  }) {
    return _lastScreenSnapshotSignature == signature &&
        _lastScreenBufferEpoch == bufferEpoch &&
        _lastScreenLayoutEpoch == layoutEpoch &&
        _lastScreenRows == rows &&
        _lastScreenCols == cols;
  }

  void markAppliedScreenSnapshot({
    required String signature,
    required int bufferEpoch,
    required int layoutEpoch,
    required int rows,
    required int cols,
  }) {
    awaitingViewportBootstrap = false;
    _lastScreenSnapshotSignature = signature;
    _lastScreenBufferEpoch = bufferEpoch;
    _lastScreenLayoutEpoch = layoutEpoch;
    _lastScreenRows = rows;
    _lastScreenCols = cols;
  }

  String decode(List<int> chunk, {bool replaceStreamState = false}) {
    if (replaceStreamState) {
      _pendingUtf8Bytes.clear();
    }

    if (chunk.isEmpty) {
      return '';
    }

    final combined = <int>[
      ..._pendingUtf8Bytes,
      ...chunk,
    ];
    final trailingLength = _trailingIncompleteUtf8Length(combined);
    final safeLength = combined.length - trailingLength;
    final safePrefix = safeLength <= 0 ? const <int>[] : combined.sublist(0, safeLength);
    _pendingUtf8Bytes
      ..clear()
      ..addAll(trailingLength <= 0 ? const <int>[] : combined.sublist(safeLength));
    if (safePrefix.isEmpty) {
      return '';
    }

    // We intentionally preserve trailing incomplete bytes so chunk boundaries
    // cannot turn a valid spinner / box-drawing glyph into a replacement
    // character. Any truly malformed bytes in the safe prefix still decode
    // lossily so the terminal can keep moving instead of throwing.
    return utf8.decode(safePrefix, allowMalformed: true);
  }

  static int _trailingIncompleteUtf8Length(List<int> bytes) {
    if (bytes.isEmpty) {
      return 0;
    }

    var continuationCount = 0;
    for (var index = bytes.length - 1; index >= 0 && continuationCount < 3; index -= 1) {
      final byte = bytes[index];
      if ((byte & 0xC0) == 0x80) {
        continuationCount += 1;
        continue;
      }

      final expectedLength = _expectedUtf8Length(byte);
      if (expectedLength == 0) {
        return 0;
      }
      if (expectedLength > continuationCount + 1) {
        return continuationCount + 1;
      }
      return 0;
    }

    return continuationCount == 0 ? 0 : continuationCount;
  }

  static int _expectedUtf8Length(int leadingByte) {
    if ((leadingByte & 0x80) == 0) {
      return 1;
    }
    if ((leadingByte & 0xE0) == 0xC0) {
      return 2;
    }
    if ((leadingByte & 0xF0) == 0xE0) {
      return 3;
    }
    if ((leadingByte & 0xF8) == 0xF0) {
      return 4;
    }
    return 0;
  }
}

@immutable
class TerminalAuthorityLine {
  const TerminalAuthorityLine({
    required this.text,
    required this.wrapped,
    required this.hardBreak,
  });

  final String text;
  final bool wrapped;
  final bool hardBreak;

  factory TerminalAuthorityLine.fromJson(Map<String, dynamic> json) {
    return TerminalAuthorityLine(
      text: json['text'] as String? ?? '',
      wrapped: json['wrapped'] as bool? ?? false,
      hardBreak: json['hard_break'] as bool? ?? true,
    );
  }
}

class TerminalAuthorityCache {
  int protocolVersion = 0;
  String? syncMode;
  int geometryGeneration = 0;
  String authoritySource = 'server_default';
  String activeBuffer = 'main';
  int bufferEpoch = 0;
  int layoutEpoch = 0;
  int historyGeneration = 0;
  int historyStartLine = 1;
  int historyEndLine = 1;
  int viewportStartLine = 1;
  int viewportEndLine = 1;
  int rows = 0;
  int cols = 0;
  final Map<int, TerminalAuthorityLine> historyLines = <int, TerminalAuthorityLine>{};
  String? _lastHistoryInvalidationSignature;

  int get cachedHistoryLineCount => historyLines.length;

  bool get shouldPreferScreenSnapshotResync {
    return _isVisibleHistoryOnly(
      previewLineCount: cachedHistoryLineCount,
    );
  }

  bool shouldTreatHistoryInvalidationAsVisibleOnly({
    required int previewLineCount,
  }) {
    return _isVisibleHistoryOnly(previewLineCount: previewLineCount);
  }

  bool _isVisibleHistoryOnly({
    required int previewLineCount,
  }) {
    if (activeBuffer != 'main') {
      return true;
    }
    final historyLineCount = historyEndLine - historyStartLine;
    final viewportLineCount = viewportEndLine - viewportStartLine;
    final effectiveRows = <int>[
      rows,
      viewportLineCount,
      previewLineCount,
      cachedHistoryLineCount,
    ].fold(0, (maxValue, value) => value > maxValue ? value : maxValue);
    // 当 history 规模没有超出当前 viewport / preview 时，authority 并没有
    // 提供可供“重建滚动历史”的额外信息，此时更接近全屏 UI / TUI 的当前
    // 屏幕镜像。继续用 transcript 重建只会把 Flutter 端已经持有的 scrollback
    // 压缩回当前 preview，表现为历史突然丢失。
    return effectiveRows > 0 &&
        historyLineCount <= effectiveRows &&
        viewportLineCount <= effectiveRows;
  }

  int? get oldestCachedLine {
    if (historyLines.isEmpty) {
      return null;
    }
    return historyLines.keys.reduce((left, right) => left < right ? left : right);
  }

  bool get isV2Authority => protocolVersion == 2 && syncMode == _terminalSyncModeV2;

  void applyStateSnapshot(Map<String, dynamic> json) {
    geometryGeneration =
        (json['geometry_generation'] as num?)?.toInt() ?? geometryGeneration;
    authoritySource = json['authority_source'] as String? ?? authoritySource;
    activeBuffer = json['active_buffer'] as String? ?? activeBuffer;
    bufferEpoch = (json['buffer_epoch'] as num?)?.toInt() ?? bufferEpoch;
    layoutEpoch = (json['layout_epoch'] as num?)?.toInt() ?? layoutEpoch;
    final main = json['main'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    historyGeneration =
        (main['history_generation'] as num?)?.toInt() ?? historyGeneration;
    historyStartLine =
        (main['history_start_line'] as num?)?.toInt() ?? historyStartLine;
    historyEndLine = (main['history_end_line'] as num?)?.toInt() ?? historyEndLine;
    viewportStartLine =
        (main['viewport_start_line'] as num?)?.toInt() ?? viewportStartLine;
    viewportEndLine = (main['viewport_end_line'] as num?)?.toInt() ?? viewportEndLine;
  }

  void applyScreenSnapshot(Map<String, dynamic> json) {
    rows = (json['rows'] as num?)?.toInt() ?? rows;
    cols = (json['cols'] as num?)?.toInt() ?? cols;
    bufferEpoch = (json['buffer_epoch'] as num?)?.toInt() ?? bufferEpoch;
    layoutEpoch = (json['layout_epoch'] as num?)?.toInt() ?? layoutEpoch;
  }

  void appendHistory(Map<String, dynamic> json) {
    final startLine = (json['start_line'] as num?)?.toInt();
    final endLine = (json['end_line'] as num?)?.toInt();
    historyGeneration =
        (json['history_generation'] as num?)?.toInt() ?? historyGeneration;
    final lines = (json['lines'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TerminalAuthorityLine.fromJson)
        .toList(growable: false);
    if (startLine == null || endLine == null || endLine < startLine) {
      return;
    }
    for (var index = 0; index < lines.length; index += 1) {
      historyLines[startLine + index] = lines[index];
    }
    historyEndLine = endLine;
    _pruneHistoryCacheWindow();
  }

  void applyLayoutChanged(Map<String, dynamic> json) {
    layoutEpoch = (json['layout_epoch'] as num?)?.toInt() ?? layoutEpoch;
    rows = (json['rows'] as num?)?.toInt() ?? rows;
    cols = (json['cols'] as num?)?.toInt() ?? cols;
  }

  void applyGeometryChanged(Map<String, dynamic> json) {
    geometryGeneration =
        (json['geometry_generation'] as num?)?.toInt() ?? geometryGeneration;
    authoritySource = json['authority_source'] as String? ?? authoritySource;
    layoutEpoch = (json['layout_epoch'] as num?)?.toInt() ?? layoutEpoch;
    rows = (json['rows'] as num?)?.toInt() ?? rows;
    cols = (json['cols'] as num?)?.toInt() ?? cols;
  }

  void applyBufferChanged(Map<String, dynamic> json) {
    activeBuffer = json['active_buffer'] as String? ?? activeBuffer;
    bufferEpoch = (json['buffer_epoch'] as num?)?.toInt() ?? bufferEpoch;
  }

  void applyTrimmed(Map<String, dynamic> json) {
    historyGeneration =
        (json['history_generation'] as num?)?.toInt() ?? historyGeneration;
    historyStartLine =
        (json['history_start_line'] as num?)?.toInt() ?? historyStartLine;
    historyEndLine = (json['history_end_line'] as num?)?.toInt() ?? historyEndLine;
    historyLines.removeWhere((lineNumber, _) => lineNumber < historyStartLine);
    _pruneHistoryCacheWindow();
  }

  void applyHistoryRangeResponse(Map<String, dynamic> json) {
    historyGeneration =
        (json['history_generation'] as num?)?.toInt() ?? historyGeneration;
    final startLine = (json['start_line'] as num?)?.toInt();
    final lines = (json['lines'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TerminalAuthorityLine.fromJson)
        .toList(growable: false);
    if (startLine == null) {
      return;
    }
    for (var index = 0; index < lines.length; index += 1) {
      historyLines[startLine + index] = lines[index];
    }
    _pruneHistoryCacheWindow();
  }

  void applyHistoryInvalidated(Map<String, dynamic> json) {
    _lastHistoryInvalidationSignature = _historyInvalidationSignature(json);
    historyGeneration =
        (json['history_generation'] as num?)?.toInt() ?? historyGeneration;
    historyStartLine =
        (json['history_start_line'] as num?)?.toInt() ?? historyStartLine;
    historyEndLine = (json['history_end_line'] as num?)?.toInt() ?? historyEndLine;
    historyLines.clear();
    final startLine = (json['start_line'] as num?)?.toInt();
    final lines = (json['lines'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TerminalAuthorityLine.fromJson)
        .toList(growable: false);
    if (startLine == null) {
      return;
    }
    for (var index = 0; index < lines.length; index += 1) {
      historyLines[startLine + index] = lines[index];
    }
    _pruneHistoryCacheWindow();
  }

  bool isDuplicateHistoryInvalidation(Map<String, dynamic> json) {
    return _lastHistoryInvalidationSignature == _historyInvalidationSignature(json);
  }

  static String _historyInvalidationSignature(Map<String, dynamic> json) {
    final lineHashes = (json['lines'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (line) => Object.hash(
            line['text'],
            line['wrapped'],
            line['hard_break'],
          ),
        );
    return [
      (json['history_generation'] as num?)?.toInt() ?? -1,
      (json['history_start_line'] as num?)?.toInt() ?? -1,
      (json['history_end_line'] as num?)?.toInt() ?? -1,
      (json['start_line'] as num?)?.toInt() ?? -1,
      (json['end_line'] as num?)?.toInt() ?? -1,
      json['reason'] as String? ?? '',
      Object.hashAll(lineHashes),
    ].join(':');
  }

  String buildTranscript() {
    if (historyLines.isEmpty) {
      return '';
    }
    final sortedEntries = historyLines.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    final buffer = StringBuffer();
    for (var index = 0; index < sortedEntries.length; index += 1) {
      final line = sortedEntries[index].value;
      buffer.write(line.text);
      if (line.hardBreak && index < sortedEntries.length - 1) {
        buffer.write('\n');
      }
    }
    return buffer.toString();
  }

  void _pruneHistoryCacheWindow() {
    if (historyLines.length <= _terminalAuthorityCacheMaxLines) {
      return;
    }
    final keys = historyLines.keys.toList(growable: false)..sort();
    final overflow = historyLines.length - _terminalAuthorityCacheMaxLines;
    for (var index = 0; index < overflow; index += 1) {
      historyLines.remove(keys[index]);
    }
  }
}

enum _TerminalTransport {
  backend,
  desktopLocal,
  sessionWebrtc,
}
