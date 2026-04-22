import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_terminal/src/terminal_view_model.dart';

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
  });
}
