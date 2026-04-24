import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:feature_terminal/src/terminal_view_model.dart';
import 'package:infra_api/infra_api.dart';
import 'package:xterm/xterm.dart';

class _FakeBackendApiClient extends Fake implements BackendApiClient {}

void main() {
  group('TerminalStreamState', () {
    test('keeps trailing utf8 bytes until the next chunk arrives', () {
      final state = TerminalStreamState();
      final spinner = '⠋';
      final bytes = utf8.encode(spinner);

      final firstChunk = bytes.sublist(0, bytes.length - 1);
      final secondChunk = bytes.sublist(bytes.length - 1);

      expect(state.decode(firstChunk), isEmpty);
      expect(state.decode(secondChunk), spinner);
    });

    test('resetDecoder clears pending utf8 tails', () {
      final state = TerminalStreamState();
      final spinner = '⠙';
      final bytes = utf8.encode(spinner);

      expect(state.decode(bytes.sublist(0, bytes.length - 1)), isEmpty);
      state.resetDecoder();

      expect(state.decode(bytes), spinner);
    });

    test('dedupes identical screen snapshots by signature and epochs', () {
      final state = TerminalStreamState();

      expect(
        state.isDuplicateScreenSnapshot(
          signature: 'screen-a',
          bufferEpoch: 4,
          layoutEpoch: 9,
          rows: 12,
          cols: 41,
        ),
        isFalse,
      );

      state.markAppliedScreenSnapshot(
        signature: 'screen-a',
        bufferEpoch: 4,
        layoutEpoch: 9,
        rows: 12,
        cols: 41,
      );

      expect(
        state.isDuplicateScreenSnapshot(
          signature: 'screen-a',
          bufferEpoch: 4,
          layoutEpoch: 9,
          rows: 12,
          cols: 41,
        ),
        isTrue,
      );
      expect(
        state.isDuplicateScreenSnapshot(
          signature: 'screen-b',
          bufferEpoch: 4,
          layoutEpoch: 9,
          rows: 12,
          cols: 41,
        ),
        isFalse,
      );
    });

    test('prepareForAttach resets interactive-frame tracking', () {
      final state = TerminalStreamState();

      expect(state.acceptsViewportResync, isTrue);
      state.markAppliedScreenSnapshot(
        signature: 'bootstrap-screen',
        bufferEpoch: 1,
        layoutEpoch: 1,
        rows: 24,
        cols: 80,
      );
      state.markInteractiveFrame();
      expect(state.hasInteractiveFrame, isTrue);
      expect(state.acceptsViewportResync, isFalse);

      state.prepareForAttach();
      expect(state.hasInteractiveFrame, isFalse);
      expect(state.acceptsViewportResync, isTrue);
    });
  });

  group('TerminalAuthorityCache', () {
    test('tracks append and trim ranges in half-open line space', () {
      final cache = TerminalAuthorityCache()
        ..protocolVersion = 2
        ..syncMode = 'state-cache-v2';

      cache.applyStateSnapshot({
        'active_buffer': 'main',
        'buffer_epoch': 3,
        'layout_epoch': 4,
        'main': {
          'history_start_line': 100,
          'history_end_line': 100,
          'viewport_start_line': 100,
          'viewport_end_line': 100,
        },
      });
      cache.appendHistory({
        'start_line': 100,
        'end_line': 102,
        'lines': [
          {'text': 'l100', 'wrapped': false, 'hard_break': true},
          {'text': 'l101', 'wrapped': false, 'hard_break': true},
        ],
      });

      expect(cache.isV2Authority, isTrue);
      expect(cache.historyLines[100]?.text, 'l100');
      expect(cache.historyLines[101]?.text, 'l101');
      expect(cache.historyEndLine, 102);

      cache.applyTrimmed({
        'history_start_line': 101,
        'history_end_line': 102,
      });

      expect(cache.historyLines.containsKey(100), isFalse);
      expect(cache.historyLines[101]?.text, 'l101');
    });

    test('history invalidation dedupe includes preview line content', () {
      final cache = TerminalAuthorityCache();
      final first = {
        'history_generation': 7,
        'history_start_line': 10,
        'history_end_line': 12,
        'start_line': 10,
        'end_line': 12,
        'reason': 'bootstrap',
        'lines': [
          {'text': 'alpha', 'wrapped': false, 'hard_break': true},
          {'text': 'beta', 'wrapped': false, 'hard_break': true},
        ],
      };
      final second = {
        'history_generation': 7,
        'history_start_line': 10,
        'history_end_line': 12,
        'start_line': 10,
        'end_line': 12,
        'reason': 'bootstrap',
        'lines': [
          {'text': 'alpha', 'wrapped': false, 'hard_break': true},
          {'text': 'gamma', 'wrapped': false, 'hard_break': true},
        ],
      };

      expect(cache.isDuplicateHistoryInvalidation(first), isFalse);
      cache.applyHistoryInvalidated(first);
      expect(cache.isDuplicateHistoryInvalidation(first), isTrue);
      expect(cache.isDuplicateHistoryInvalidation(second), isFalse);
    });

    test('buildTranscript overlays latest screen snapshot onto cached history tail', () {
      final cache = TerminalAuthorityCache()
        ..activeBuffer = 'main'
        ..historyStartLine = 0
        ..historyEndLine = 3
        ..viewportStartLine = 1
        ..viewportEndLine = 3;

      cache.applyHistoryInvalidated({
        'history_generation': 11,
        'history_start_line': 0,
        'history_end_line': 3,
        'start_line': 0,
        'end_line': 3,
        'reason': 'geometry_changed',
        'lines': [
          {'text': 'line-0', 'wrapped': false, 'hard_break': true},
          {'text': 'old-1', 'wrapped': false, 'hard_break': true},
          {'text': 'old-2', 'wrapped': false, 'hard_break': true},
        ],
      });
      cache.applyScreenSnapshot({
        'rows': 2,
        'cols': 40,
        'cursor_row': 1,
        'cursor_col': 3,
        'screen_lines': [
          {'text': 'new-1', 'wrapped': false, 'hard_break': true},
          {'text': 'new-2', 'wrapped': false, 'hard_break': true},
        ],
      });

      expect(cache.buildTranscript(), 'line-0\r\nnew-1\r\nnew-2');
    });

    test('buildReplayBytes prefers formatted screen data so visible colors survive', () {
      final cache = TerminalAuthorityCache()
        ..activeBuffer = 'main'
        ..historyStartLine = 0
        ..historyEndLine = 3
        ..viewportStartLine = 1
        ..viewportEndLine = 3;

      cache.applyHistoryInvalidated({
        'history_generation': 11,
        'history_start_line': 0,
        'history_end_line': 3,
        'start_line': 0,
        'end_line': 3,
        'reason': 'bootstrap',
        'lines': [
          {'text': 'line-0', 'wrapped': false, 'hard_break': true},
          {'text': 'old-1', 'wrapped': false, 'hard_break': true},
          {'text': 'old-2', 'wrapped': false, 'hard_break': true},
        ],
      });
      cache.applyScreenSnapshot({
        'rows': 2,
        'cols': 40,
        'cursor_row': 1,
        'cursor_col': 3,
        'screen_data_base64': base64Encode(
          utf8.encode('\u001b[31mnew-1\u001b[0m\r\n\u001b[32mnew-2\u001b[0m'),
        ),
        'screen_lines': [
          {'text': 'new-1', 'wrapped': false, 'hard_break': true},
          {'text': 'new-2', 'wrapped': false, 'hard_break': true},
        ],
      });

      final replay = utf8.decode(cache.buildReplayBytes(), allowMalformed: true);
      expect(
        replay,
        'line-0\r\n\u001b[31mnew-1\u001b[0m\r\n\u001b[32mnew-2\u001b[0m',
      );
    });

    test('empty screen_data_base64 clears stale formatted replay bytes', () {
      final cache = TerminalAuthorityCache()
        ..activeBuffer = 'main'
        ..historyStartLine = 0
        ..historyEndLine = 2
        ..viewportStartLine = 1
        ..viewportEndLine = 2;

      cache.applyHistoryInvalidated({
        'history_generation': 7,
        'history_start_line': 0,
        'history_end_line': 2,
        'start_line': 0,
        'end_line': 2,
        'reason': 'bootstrap',
        'lines': [
          {'text': 'line-0', 'wrapped': false, 'hard_break': true},
          {'text': 'old-1', 'wrapped': false, 'hard_break': true},
        ],
      });
      cache.applyScreenSnapshot({
        'rows': 1,
        'cols': 40,
        'cursor_row': 0,
        'cursor_col': 0,
        'screen_data_base64': base64Encode(utf8.encode('\u001b[31mold-1\u001b[0m')),
        'screen_lines': [
          {'text': 'old-1', 'wrapped': false, 'hard_break': true},
        ],
      });

      cache.applyScreenSnapshot({
        'rows': 1,
        'cols': 40,
        'cursor_row': 0,
        'cursor_col': 0,
        'screen_data_base64': '',
        'screen_lines': [
          {'text': 'new-1', 'wrapped': false, 'hard_break': true},
        ],
      });

      expect(utf8.decode(cache.buildReplayBytes()), 'line-0\r\nnew-1');
    });

    test('CRLF hard breaks keep xterm replay left aligned across commands', () {
      final lfOnly = Terminal(maxLines: 100)..resize(40, 6);
      lfOnly.write('prompt> \nprompt> \nprompt> ');

      final crlf = Terminal(maxLines: 100)..resize(40, 6);
      crlf.write('prompt> \r\nprompt> \r\nprompt> ');

      int firstOccupiedColumn(Terminal terminal, int row) {
        final line = terminal.buffer.lines[row];
        for (var col = 0; col < terminal.viewWidth; col += 1) {
          if (line.getCodePoint(col) != 0) {
            return col;
          }
        }
        return -1;
      }

      expect(lfOnly.buffer.lines[0].getText(0, 20), 'prompt> ');
      expect(firstOccupiedColumn(lfOnly, 1), greaterThan(0));
      expect(firstOccupiedColumn(lfOnly, 2), greaterThan(firstOccupiedColumn(lfOnly, 1)));

      expect(crlf.buffer.lines[0].getText(0, 20), 'prompt> ');
      expect(firstOccupiedColumn(crlf, 1), 0);
      expect(firstOccupiedColumn(crlf, 2), 0);
      expect(crlf.buffer.lines[1].getText(0, 20), 'prompt> ');
      expect(crlf.buffer.lines[2].getText(0, 20), 'prompt> ');
    });
  });

  group('TerminalVisibleWindowPlanner', () {
    test('keeps viewer height and lifts visible text toward the middle', () {
      final screenLines = [
        ...List.generate(
          30,
          (_) => TerminalAuthorityLine(
            text: '',
            wrapped: false,
            hardBreak: true,
          ),
        ),
        ...List.generate(
          20,
          (index) => TerminalAuthorityLine(
            text: 'line-$index',
            wrapped: false,
            hardBreak: true,
          ),
        ),
        ...List.generate(
          30,
          (_) => TerminalAuthorityLine(
            text: '',
            wrapped: false,
            hardBreak: true,
          ),
        ),
      ];

      final plan = TerminalVisibleWindowPlanner.plan(
        screenLines: screenLines,
        cursorRow: 49,
        cursorCol: 3,
        viewerRows: 20,
      );

      expect(plan.lines.length, 20);
      expect(plan.trailingBlankLines, 30);
      expect(plan.topOffset, 30);
      expect(plan.lines[0].text, 'line-0');
      expect(plan.lines[9].text, 'line-9');
      expect(plan.cursorRow, 19);
    });

    test('reuses locked top offset after the first positioning', () {
      final screenLines = [
        ...List.generate(
          30,
          (index) => TerminalAuthorityLine(
            text: index >= 18 ? 'line-$index' : '',
            wrapped: false,
            hardBreak: true,
          ),
        ),
      ];

      final first = TerminalVisibleWindowPlanner.plan(
        screenLines: screenLines,
        cursorRow: 29,
        cursorCol: 0,
        viewerRows: 10,
      );
      final second = TerminalVisibleWindowPlanner.plan(
        screenLines: screenLines,
        cursorRow: 29,
        cursorCol: 0,
        viewerRows: 10,
        lockedTopOffset: first.topOffset,
      );

      expect(second.topOffset, first.topOffset);
    });

    test('falls back to cursor anchoring when snapshot lines are blank', () {
      final screenLines = List.generate(
        76,
        (_) => TerminalAuthorityLine(
          text: '',
          wrapped: false,
          hardBreak: true,
        ),
      );

      final plan = TerminalVisibleWindowPlanner.plan(
        screenLines: screenLines,
        cursorRow: 75,
        cursorCol: 0,
        viewerRows: 48,
      );

      expect(plan.topOffset, 28);
      expect(plan.cursorRow, 47);
      expect(plan.lines.length, 48);
    });
  });

  group('TerminalPageConfig provider identity', () {
    test('ignores device bootstrap changes so desktop keeps one terminal vm', () {
      const pendingRegistration = TerminalPageConfig(
        accessToken: 'token',
        deviceId: null,
        sessionId: null,
      );
      const registeredDevice = TerminalPageConfig(
        accessToken: 'token',
        deviceId: 'device-001',
        sessionId: null,
      );

      expect(pendingRegistration, registeredDevice);
      expect(pendingRegistration.hashCode, registeredDevice.hashCode);

      final container = ProviderContainer(
        overrides: [
          backendApiClientProvider.overrideWithValue(_FakeBackendApiClient()),
          backendEventClientProvider.overrideWithValue(null),
          desktopLocalClientProvider.overrideWithValue(
            DesktopLocalClient(host: '127.0.0.1', portStart: 46111, portEnd: 46119),
          ),
        ],
      );
      addTearDown(container.dispose);

      final firstVm = container.read(terminalViewModelProvider(pendingRegistration).notifier);
      final secondVm = container.read(terminalViewModelProvider(registeredDevice).notifier);

      expect(identical(firstVm, secondVm), isTrue);
    });

    test('same remote session keeps deviceId in provider identity', () {
      const deviceA = TerminalPageConfig(
        accessToken: 'token',
        deviceId: 'device-a',
        sessionId: 'session-1',
      );
      const deviceB = TerminalPageConfig(
        accessToken: 'token',
        deviceId: 'device-b',
        sessionId: 'session-1',
      );

      expect(deviceA, isNot(deviceB));
      expect(deviceA.hashCode, isNot(deviceB.hashCode));
    });

    test('still isolates different remote sessions into different vms', () {
      const sessionA = TerminalPageConfig(
        accessToken: 'token',
        deviceId: 'device-001',
        sessionId: 'session-a',
      );
      const sessionB = TerminalPageConfig(
        accessToken: 'token',
        deviceId: 'device-001',
        sessionId: 'session-b',
      );

      expect(sessionA, isNot(sessionB));
    });
  });
}
