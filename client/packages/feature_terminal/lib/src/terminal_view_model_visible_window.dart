part of 'terminal_view_model.dart';

@immutable
class TerminalVisibleWindowPlan {
  const TerminalVisibleWindowPlan({
    required this.lines,
    required this.cursorRow,
    required this.cursorCol,
    required this.topOffset,
    required this.trailingBlankLines,
  });

  final List<TerminalAuthorityLine> lines;
  final int cursorRow;
  final int cursorCol;
  final int topOffset;
  final int trailingBlankLines;
}

class TerminalVisibleWindowPlanner {
  const TerminalVisibleWindowPlanner._();

  static TerminalVisibleWindowPlan plan({
    required List<TerminalAuthorityLine> screenLines,
    required int cursorRow,
    required int cursorCol,
    required int viewerRows,
    int? lockedTopOffset,
    int maxTrailingBlankRows = _terminalVisibleSnapshotMaxTrailingBlankRows,
  }) {
    if (screenLines.isEmpty) {
      return TerminalVisibleWindowPlan(
        lines: const [],
        cursorRow: 0,
        cursorCol: cursorCol < 0 ? 0 : cursorCol,
        topOffset: 0,
        trailingBlankLines: 0,
      );
    }

    final trailingBlankLines = _countTrailingBlankLines(screenLines);
    final windowRows =
        viewerRows > 0 ? viewerRows.clamp(1, screenLines.length) : screenLines.length;

    if (windowRows >= screenLines.length) {
      return TerminalVisibleWindowPlan(
        lines: List<TerminalAuthorityLine>.from(screenLines, growable: false),
        cursorRow: cursorRow.clamp(0, screenLines.length - 1),
        cursorCol: cursorCol < 0 ? 0 : cursorCol,
        topOffset: 0,
        trailingBlankLines: trailingBlankLines,
      );
    }

    final normalizedCursorCol = cursorCol < 0 ? 0 : cursorCol;
    final clampedCursorRow = cursorRow.clamp(0, screenLines.length - 1);
    final firstTextRow = _findFirstNonBlankLine(screenLines);
    final lastTextRow = _findLastNonBlankLine(screenLines);
    final maxStart = screenLines.length - windowRows;
    int start;
    if (lockedTopOffset != null) {
      start = lockedTopOffset.clamp(0, maxStart).toInt();
    } else if (firstTextRow == null || lastTextRow == null) {
      // 当首帧 screen snapshot 暂时拿不到可读文本（例如只剩 cursor/空白区）
      // 时，仍然需要保证 cursor 落在本地可见窗口里。这里退回到“按 cursor
      // 定位窗口”的策略：把 cursor 放在窗口下半区，避免 Desktop App 一直
      // 卡在远端超高终端的最底部空白区域。
      start = clampedCursorRow - ((windowRows * 2) ~/ 3);
      if (start < 0) {
        start = 0;
      }
      if (start > maxStart) {
        start = maxStart;
      }
    } else {
      final textCenterRow = ((firstTextRow + lastTextRow) / 2).round();
      final targetCenterRow = windowRows ~/ 2;
      start = textCenterRow - targetCenterRow;
      if (start < 0) {
        start = 0;
      }
      if (start > maxStart) {
        start = maxStart;
      }

      final blankCapStart =
          (lastTextRow + 1 + maxTrailingBlankRows - windowRows).clamp(0, maxStart).toInt();
      if (trailingBlankLines > maxTrailingBlankRows) {
        start = start.clamp(0, blankCapStart).toInt();
      }
    }

    final slicedLines = screenLines
        .sublist(start, start + windowRows)
        .toList(growable: false);

    return TerminalVisibleWindowPlan(
      lines: slicedLines,
      cursorRow: (clampedCursorRow - start).clamp(0, slicedLines.length - 1),
      cursorCol: normalizedCursorCol,
      topOffset: start,
      trailingBlankLines: trailingBlankLines,
    );
  }

  static bool hasMeaningfulVisibleText(List<TerminalAuthorityLine> lines) {
    return _findFirstNonBlankLine(lines) != null;
  }

  static int inferredCursorRowForDisplay(List<TerminalAuthorityLine> lines) {
    return _findLastNonBlankLine(lines) ?? 0;
  }

  static int _countTrailingBlankLines(List<TerminalAuthorityLine> lines) {
    var count = 0;
    for (var index = lines.length - 1; index >= 0; index -= 1) {
      if (lines[index].text.trim().isEmpty) {
        count += 1;
        continue;
      }
      break;
    }
    return count;
  }

  static int? _findFirstNonBlankLine(List<TerminalAuthorityLine> lines) {
    for (var index = 0; index < lines.length; index += 1) {
      if (lines[index].text.trim().isNotEmpty) {
        return index;
      }
    }
    return null;
  }

  static int? _findLastNonBlankLine(List<TerminalAuthorityLine> lines) {
    for (var index = lines.length - 1; index >= 0; index -= 1) {
      if (lines[index].text.trim().isNotEmpty) {
        return index;
      }
    }
    return null;
  }
}

