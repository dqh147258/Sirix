import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalThemes;

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

import 'terminal_state.dart';

const Duration _terminalInputDebounce = Duration(milliseconds: 12);
const Duration _terminalResizeTrailingDebounce = Duration(milliseconds: 32);
const Duration _terminalMobileResizeDebounce = Duration(milliseconds: 96);
const Duration _terminalSessionAttachRetryDelay = Duration(milliseconds: 180);
const Duration _desktopLocalAttachReconcileDelay = Duration(milliseconds: 220);
const Duration _terminalSessionListRetryDelay = Duration(milliseconds: 320);
const Duration _terminalSessionListTimeout = Duration(milliseconds: 2400);
const int _terminalImmediateInputThreshold = 128;
const int _terminalSessionAttachRetryCount = 6;
const int _terminalSessionListRetryCount = 3;
const int _terminalAuthorityCacheMaxLines = 1600;
const String _terminalStreamTraceTag = '[TERMINAL_STREAM_TRACE]';
const String _terminalSyncModeV2 = 'state-cache-v2';
const String _terminalOscTraceTag = '[TERMINAL_OSC_TRACE]';
const Duration _terminalAuthorityRefreshInterval = Duration(milliseconds: 500);
const Duration _terminalVisibleSnapshotApplyInterval = Duration(milliseconds: 1000);

@immutable
class TerminalPageConfig {
  const TerminalPageConfig({
    required this.accessToken,
    required this.deviceId,
    required this.sessionId,
  });

  // UI presentation flags are intentionally excluded so every entry point
  // shares the same terminal workspace for a given authenticated session/device.
  final String accessToken;
  final String? deviceId;
  final String? sessionId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TerminalPageConfig &&
            runtimeType == other.runtimeType &&
            accessToken == other.accessToken &&
            deviceId == other.deviceId &&
            sessionId == other.sessionId;
  }

  @override
  int get hashCode => Object.hash(accessToken, deviceId, sessionId);
}

class TerminalViewModel extends BaseViewModel<TerminalState> {
  TerminalViewModel({
    required BackendApiClient apiClient,
    required BackendEventClient? eventClient,
    required DesktopLocalClient? desktopLocalClient,
    required SessionTerminalChannelController sessionTerminalChannelController,
    required TerminalPageConfig config,
  })  : _apiClient = apiClient,
        _eventClient = eventClient,
        _desktopLocalClient = desktopLocalClient,
        _sessionTerminalChannelController = sessionTerminalChannelController,
        _config = config,
        super(const TerminalState()) {
    _sessionChannelSubscription =
        _sessionTerminalChannelController.messages.listen(_handleSessionChannelEvent);
  }

  final BackendApiClient _apiClient;
  final BackendEventClient? _eventClient;
  final DesktopLocalClient? _desktopLocalClient;
  final SessionTerminalChannelController _sessionTerminalChannelController;
  TerminalPageConfig _config;
  final Map<String, Terminal> _terminalCache = <String, Terminal>{};
  final Map<String, TerminalStreamState> _terminalStreams = <String, TerminalStreamState>{};
  final Map<String, TerminalAuthorityCache> _terminalAuthorities =
      <String, TerminalAuthorityCache>{};
  final Map<String, int> _viewerPresenceEpochByTerminal = <String, int>{};
  final Set<String> _snapshotApplyingTerminals = <String>{};
  final Set<String> _autoCreatedTerminalIds = <String>{};

  WebSocketChannel? _channel;
  _TerminalTransport? _transport;
  StreamSubscription<dynamic>? _channelSubscription;
  StreamSubscription<Map<String, dynamic>>? _sessionChannelSubscription;
  Timer? _inputTimer;
  Timer? _resizeTimer;
  _QueuedInput? _pendingInput;
  _QueuedResize? _pendingResize;
  int _historyRequestSequence = 0;
  final Map<String, Set<String>> _pendingHistoryRangesByTerminal = <String, Set<String>>{};
  final Map<String, _TerminalViewportSize> _lastDispatchedResizeByTerminal =
      <String, _TerminalViewportSize>{};
  final Map<String, Timer> _pendingAuthorityRefreshTimers = <String, Timer>{};
  final Map<String, _PendingAuthorityRefresh> _pendingAuthorityRefreshes =
      <String, _PendingAuthorityRefresh>{};
  final Map<String, Timer> _pendingVisibleSnapshotTimers = <String, Timer>{};
  final Map<String, _PendingScreenSnapshotApply> _pendingVisibleSnapshotApplies =
      <String, _PendingScreenSnapshotApply>{};
  _TerminalViewportSize? _lastObservedViewportSize;
  bool _resizeTrailingWindowActive = false;
  Completer<List<TerminalSessionSummary>>? _pendingSessionTerminalListCompleter;
  bool _hasLoaded = false;
  bool _loadingInFlight = false;
  bool _creatingInFlight = false;
  bool _disposed = false;

  void updateConfig(TerminalPageConfig config) {
    _config = config;
  }

  Future<void> load({bool force = false}) async {
    if (_loadingInFlight || (_hasLoaded && !force)) {
      return;
    }

    _hasLoaded = true;
    _loadingInFlight = true;
    state = state.copyWith(loading: true, clearError: true);

    if (_shouldWaitForRemoteSession || _shouldWaitForSessionTransport) {
      await _detachChannel();
      state = state.copyWith(
        loading: false,
        terminals: const [],
        clearActiveTerminalId: true,
        clearError: true,
      );
      _loadingInFlight = false;
      return;
    }

    try {
      final terminals = _shouldUseDesktopLocalTransport
          ? await _loadDesktopLocalTerminals()
          : _shouldUseSessionTransport
              ? await _loadSessionTransportTerminals()
              : await _apiClient.listTerminals(
                  accessToken: _config.accessToken,
                  deviceId: _config.deviceId,
                );
      _replaceTerminals(terminals);
      state = state.copyWith(loading: false, clearError: true);

      if (state.terminals.isEmpty) {
        if (_shouldAutoCreateDefaultTerminal) {
          await createTerminal(autoCreated: true);
        } else {
          await _detachChannel();
        }
        return;
      }

      final nextTerminalId = _resolveTerminalToActivate(terminals);
      if (nextTerminalId != null) {
        await attachTerminal(nextTerminalId);
      }
    } catch (error) {
      state = state.copyWith(
        loading: false,
        errorMessage: AppLocalizations.current.terminalLoadFailed('$error'),
      );
    } finally {
      _loadingInFlight = false;
    }
  }

  Future<void> refresh() => load(force: true);

  Future<List<TerminalSessionSummary>> _loadDesktopLocalTerminals() async {
    final localClient = _desktopLocalClient;
    if (localClient == null) {
      return _apiClient.listTerminals(
        accessToken: _config.accessToken,
        deviceId: _config.deviceId,
      );
    }

    try {
      return await localClient.listTerminalSessions();
    } catch (error, stackTrace) {
      AppLogger.warn('desktop local terminal list failed error=$error');
      AppLogger.warn('desktop local terminal list stack: $stackTrace');
      return _apiClient.listTerminals(
        accessToken: _config.accessToken,
        deviceId: _config.deviceId,
      );
    }
  }

  Future<List<TerminalSessionSummary>> _loadSessionTransportTerminals() async {
    final existingCompleter = _pendingSessionTerminalListCompleter;
    if (existingCompleter != null) {
      return existingCompleter.future;
    }

    var lastKnown = state.terminals;
    for (var attempt = 0; attempt < _terminalSessionListRetryCount; attempt += 1) {
      final completer = Completer<List<TerminalSessionSummary>>();
      _pendingSessionTerminalListCompleter = completer;

      final sent = await _sessionTerminalChannelController.sendJson({
        'type': 'terminal.list',
      });
      if (!sent) {
        _pendingSessionTerminalListCompleter = null;
        AppLogger.warn('session terminal list request skipped: data channel unavailable');
        return lastKnown;
      }

      try {
        final terminals = await completer.future.timeout(_terminalSessionListTimeout);
        if (terminals.isNotEmpty || attempt == _terminalSessionListRetryCount - 1) {
          return terminals;
        }
        lastKnown = terminals;
      } on TimeoutException {
        if (identical(_pendingSessionTerminalListCompleter, completer)) {
          _pendingSessionTerminalListCompleter = null;
        }
        AppLogger.warn(
          'session terminal list timed out attempt=${attempt + 1}/$_terminalSessionListRetryCount',
        );
        if (attempt == _terminalSessionListRetryCount - 1) {
          return lastKnown;
        }
      }

      await Future<void>.delayed(_terminalSessionListRetryDelay);
    }

    return lastKnown;
  }

  Future<void> createTerminal({bool autoCreated = false}) async {
    final deviceId = _config.deviceId;
    if (deviceId == null || _creatingInFlight || (_loadingInFlight && !autoCreated)) {
      return;
    }

    _creatingInFlight = true;
    state = state.copyWith(clearError: true);

    try {
      final created = await _apiClient.createTerminal(
        accessToken: _config.accessToken,
        targetDeviceId: deviceId,
        cols: _preferredCols,
        rows: _preferredRows,
      );
      if (autoCreated) {
        _autoCreatedTerminalIds.add(created.id);
        AppLogger.info(
          '$_terminalStreamTraceTag auto created placeholder terminalId=${created.id}',
        );
      } else {
        _autoCreatedTerminalIds.remove(created.id);
      }
      if (_config.sessionId != null) {
        await load(force: true);
        await attachTerminal(created.id);
        return;
      }

      final terminals = [...state.terminals, created];
      state = state.copyWith(
        terminals: terminals,
        activeTerminalId: created.id,
        clearError: true,
      );
      await attachTerminal(created.id);
    } catch (error) {
      if (autoCreated) {
        AppLogger.warn('auto terminal create failed deviceId=$deviceId error=$error');
      }
      state = state.copyWith(
        errorMessage: AppLocalizations.current.terminalCreateFailed('$error'),
      );
    } finally {
      _creatingInFlight = false;
    }
  }

  Future<void> closeActiveTerminal() async {
    final terminalId = state.activeTerminalId;
    if (terminalId == null) {
      return;
    }

    await closeTerminal(terminalId);
  }

  Future<void> closeTerminal(String terminalId) async {
    if (_config.sessionId != null) {
      try {
        await _requestTerminalClose(terminalId);
        await load(force: true);
      } catch (error) {
        state = state.copyWith(
          errorMessage: AppLocalizations.current.terminalCloseFailed('$error'),
        );
      }
      return;
    }

    final terminalsBeforeClose = state.terminals;
    final closingActive = state.activeTerminalId == terminalId;

    try {
      await _requestTerminalClose(terminalId);
      final remaining = terminalsBeforeClose
          .where((item) => item.id != terminalId)
          .toList(growable: false);
      final nextActiveId = closingActive
          ? _resolveNextTerminalAfterClose(
              terminalId: terminalId,
              terminalsBeforeClose: terminalsBeforeClose,
              remaining: remaining,
            )
          : state.activeTerminalId;
      state = state.copyWith(
        terminals: remaining,
        activeTerminalId: nextActiveId,
        clearActiveTerminalId: closingActive && nextActiveId == null,
        clearError: true,
      );

      if (closingActive) {
        await _detachChannel();

        if (nextActiveId != null) {
          await attachTerminal(nextActiveId);
        } else if (_shouldAutoCreateDefaultTerminal) {
          await createTerminal(autoCreated: true);
        }
      }
    } catch (error) {
      state = state.copyWith(
        errorMessage: AppLocalizations.current.terminalCloseFailed('$error'),
      );
    }
  }

  Future<void> _requestTerminalClose(String terminalId) async {
    if (_shouldUseSessionTransport) {
      final sent = await _sessionTerminalChannelController.sendJson({
        'type': 'terminal.close',
        'terminal_id': terminalId,
      });
      if (sent) {
        return;
      }
    }

    if (_shouldUseDesktopLocalTransport) {
      final localClient = _desktopLocalClient;
      if (localClient != null) {
        try {
          final channel = await _connectDesktopLocalChannel();
          localClient.sendTerminalClose(
            channel: channel,
            terminalId: terminalId,
          );
          return;
        } catch (error, stackTrace) {
          AppLogger.warn('desktop local terminal close failed terminalId=$terminalId error=$error');
          AppLogger.warn('desktop local terminal close stack: $stackTrace');
        }
      }
    }

    await _apiClient.closeTerminal(
      accessToken: _config.accessToken,
      terminalId: terminalId,
    );
  }

  Future<void> attachTerminal(
    String terminalId,
  ) async {
    final previousActiveId = state.activeTerminalId;
    final alreadyAttached = state.activeTerminalId == terminalId &&
        !state.connecting &&
        ((_transport == _TerminalTransport.sessionWebrtc && _shouldUseSessionTransport) ||
            _channel != null);
    if (alreadyAttached) {
      return;
    }

    if (_transport == _TerminalTransport.desktopLocal ||
        _transport == _TerminalTransport.sessionWebrtc) {
      _flushPendingOutboundOperations();
    } else {
      await _detachChannel();
    }
    state = state.copyWith(
      activeTerminalId: terminalId,
      connecting: true,
      clearError: true,
    );
    // 每次重新 attach 时都清掉本地的“已经收到首帧”标记，避免移动端
    // WebRTC data channel 重连后沿用旧状态，导致 bootstrap 重试提前停掉。
    _streamStateFor(terminalId).prepareForAttach();
    _lastDispatchedResizeByTerminal.remove(terminalId);
    if (previousActiveId != null && previousActiveId != terminalId) {
      final inheritedViewport = _lastDispatchedResizeByTerminal[previousActiveId] ??
          _lastObservedViewportSize;
      if (inheritedViewport != null) {
        _lastDispatchedResizeByTerminal[terminalId] = inheritedViewport;
        AppLogger.info(
          '$_terminalStreamTraceTag seed viewport terminalId=$terminalId from=$previousActiveId size=${inheritedViewport.cols}x${inheritedViewport.rows}',
        );
      }
    }

    if (_shouldUseSessionTransport) {
      await _detachChannel();
      _transport = _TerminalTransport.sessionWebrtc;
      final sent = await _sessionTerminalChannelController.sendJson({
        'type': 'terminal.attach',
        'payload': {
          'terminal_id': terminalId,
          'protocol_version': 2,
          'sync_mode': _terminalSyncModeV2,
          'client_kind': 'mobile_app',
        },
      });
      if (sent) {
        await _sessionTerminalChannelController.sendJson({
          'type': 'terminal.bootstrap.request',
          'payload': {
            'terminal_id': terminalId,
          },
        });
        if (_shouldRetrySessionAttach(terminalId)) {
          unawaited(_retrySessionAttachUntilReady(terminalId));
        }
        state = state.copyWith(connecting: false);
        return;
      }
      _transport = null;
    }

    if (_shouldUseDesktopLocalTransport) {
      try {
        final channel = await _connectDesktopLocalChannel();
        final localClient = _desktopLocalClient!;
        localClient.sendTerminalAttach(
          channel: channel,
          terminalId: terminalId,
          clientKind: 'desktop_app',
        );
        localClient.sendTerminalBootstrapRequest(
          channel: channel,
          terminalId: terminalId,
        );
        if (_shouldRetryDesktopLocalAttach(terminalId)) {
          unawaited(_retryDesktopLocalAttachUntilReady(terminalId));
        }
        state = state.copyWith(connecting: false);
        return;
      } catch (error, stackTrace) {
        AppLogger.warn('desktop local terminal attach failed terminalId=$terminalId error=$error');
        AppLogger.warn('desktop local terminal attach stack: $stackTrace');
      }
    }

    final eventClient = _eventClient;
    if (eventClient == null) {
      state = state.copyWith(
        connecting: false,
        errorMessage: AppLocalizations.current.terminalStreamUnavailable,
      );
      return;
    }

    try {
      final channel = eventClient.connectTerminalEvents(
        accessToken: _config.accessToken,
        terminalId: terminalId,
      );
      _channel = channel;
      _transport = _TerminalTransport.backend;
      _channelSubscription = channel.stream.listen(
        (raw) => _handleSocketEvent(channel, raw),
        onError: (Object error, StackTrace stackTrace) {
          if (!identical(_channel, channel)) {
            return;
          }
          state = state.copyWith(
            connecting: false,
            errorMessage: AppLocalizations.current.terminalStreamError('$error'),
          );
        },
        onDone: () {
          if (!identical(_channel, channel)) {
            return;
          }
          state = state.copyWith(connecting: false);
        },
      );
      channel.sink.add(
        jsonEncode({
          'type': 'terminal.attach',
          'payload': {
            'terminal_id': terminalId,
            'protocol_version': 2,
            'sync_mode': _terminalSyncModeV2,
            'client_kind': _shouldUseSessionTransport ? 'mobile_app' : 'desktop_app',
          },
        }),
      );
      channel.sink.add(
        jsonEncode({
          'type': 'terminal.bootstrap.request',
          'payload': {
            'terminal_id': terminalId,
          },
        }),
      );
      state = state.copyWith(connecting: false);
    } catch (error) {
      state = state.copyWith(
        connecting: false,
        errorMessage: AppLocalizations.current.terminalConnectFailed('$error'),
      );
    }
  }

  void queueInput({
    required String terminalId,
    required String data,
  }) {
    if (data.isEmpty) {
      return;
    }

    var pendingInput = _pendingInput;
    if (pendingInput == null || pendingInput.terminalId != terminalId) {
      _flushPendingInput();
      pendingInput = _QueuedInput(terminalId: terminalId);
      _pendingInput = pendingInput;
    }

    pendingInput.buffer.write(data);
    if (_shouldFlushInputImmediately(data)) {
      _flushPendingInput();
      return;
    }

    _inputTimer?.cancel();
    _inputTimer = Timer(_terminalInputDebounce, _flushPendingInput);
  }

  void queueResize({
    required String terminalId,
    required int cols,
    required int rows,
  }) {
    if (cols <= 0 || rows <= 0) {
      return;
    }

    final pendingResize = _pendingResize;
    if (pendingResize != null &&
        pendingResize.terminalId == terminalId &&
        pendingResize.cols == cols &&
        pendingResize.rows == rows) {
      return;
    }
    final dispatchedSize = _lastDispatchedResizeByTerminal[terminalId];
    if (pendingResize == null &&
        dispatchedSize != null &&
        dispatchedSize.cols == cols &&
        dispatchedSize.rows == rows) {
      return;
    }

    _pendingResize = _QueuedResize(
      terminalId: terminalId,
      cols: cols,
      rows: rows,
    );
    if (_shouldUseMobileResizeCoalescing) {
      // 移动端软键盘弹出/收起期间会连续触发多次高度变化；若把这些中间态
      // 全量发到桌面端，桌面端会重复生成 screen snapshot，再经 WebRTC
      // 回流到 Flutter，最终表现为输入卡顿、界面闪烁和 TUI 重绘迟滞。
      // 这里改成仅发送动画尾部的最终尺寸，显著降低 snapshot churn。
      _resizeTrailingWindowActive = false;
      _resizeTimer?.cancel();
      _resizeTimer = Timer(_terminalMobileResizeDebounce, _flushPendingResize);
      return;
    }

    if (!_resizeTrailingWindowActive) {
      // The first geometry change must reach the PTY immediately so cursor-up
      // redraws and wrapped output do not continue rendering against the old
      // column count for another debounce window.
      _resizeTrailingWindowActive = true;
      AppLogger.info(
        '$_terminalStreamTraceTag immediate resize terminalId=$terminalId cols=$cols rows=$rows',
      );
      _flushPendingResize();
      _resizeTimer?.cancel();
      _resizeTimer = Timer(
        _terminalResizeTrailingDebounce,
        _flushPendingResizeAtTrailingEdge,
      );
      return;
    }

    _resizeTimer?.cancel();
    _resizeTimer = Timer(
      _terminalResizeTrailingDebounce,
      _flushPendingResizeAtTrailingEdge,
    );
  }

  Terminal? terminalFor(String? terminalId) {
    if (terminalId == null || terminalId.isEmpty) {
      return null;
    }

    _streamStateFor(terminalId);
    return _terminalCache.putIfAbsent(terminalId, () => _createTerminal(terminalId));
  }

  TerminalAuthorityCache? authorityFor(String? terminalId) {
    if (terminalId == null || terminalId.isEmpty) {
      return null;
    }
    return _terminalAuthorities[terminalId];
  }

  bool _shouldOptimisticallyUpdateSummaryForResize(String terminalId) {
    if (_shouldUseAuthorityViewportSizing) {
      return false;
    }

    final authoritySource = _terminalAuthorities[terminalId]?.authoritySource;
    if (authoritySource == 'system_terminal') {
      // 当系统终端仍然在线时，它才是 PTY 几何的唯一权威来源。Desktop App
      // 自己的可视区大小只能作为候选值缓存，不能覆盖 terminal summary，
      // 否则 UI 会错误地把 viewer 宽度当成真实终端宽度，导致内容宽度和
      // 当前屏幕快照都与系统终端错位。
      return false;
    }
    return true;
  }

  TerminalStreamState _streamStateFor(String terminalId) {
    return _terminalStreams.putIfAbsent(terminalId, TerminalStreamState.new);
  }

  Terminal _createTerminal(String terminalId) {
    final terminal = Terminal(maxLines: 10000);
    terminal.onOutput = (data) {
      queueInput(
        terminalId: terminalId,
        data: data,
      );
    };
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_snapshotApplyingTerminals.contains(terminalId)) {
        AppLogger.info(
          '$_terminalStreamTraceTag suppress resize during snapshot apply terminalId=$terminalId cols=$width rows=$height',
        );
        return;
      }
      queueResize(
        terminalId: terminalId,
        cols: width,
        rows: height,
      );
    };
    terminal.onPrivateOSC = (code, args) {
      _handleTerminalPrivateOsc(
        terminalId: terminalId,
        code: code,
        args: args,
      );
    };
    return terminal;
  }

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
    final buffer = StringBuffer();
    for (var index = 0; index < screenLines.length; index += 1) {
      buffer.write(screenLines[index].text);
      if (index < screenLines.length - 1) {
        buffer.write('\r\n');
      }
    }
    buffer.write('\x1b[${cursorRow + 1};${cursorCol + 1}H');

    _runWithSnapshotApplyGuard(terminalId, () {
      _applyAuthorityViewportIfNeeded(terminalId, terminal);
      _resetTerminalSnapshot(terminal);
      streamState.resetDecoder();
      terminal.write(buffer.toString());
    });
    AppLogger.info(
      '$_terminalStreamTraceTag applied line snapshot terminalId=$terminalId rows=${screenLines.length} cursor=$cursorRow:$cursorCol',
    );
  }



  void _scheduleAuthorityRefresh(
    String terminalId, {
    required String reason,
  }) {
    final authority = _terminalAuthorities[terminalId];
    if (authority == null) {
      return;
    }
    _pendingAuthorityRefreshes[terminalId] = _PendingAuthorityRefresh(
      reason: reason,
      generation: authority.historyGeneration,
      layoutEpoch: authority.layoutEpoch,
      bufferEpoch: authority.bufferEpoch,
    );
    final existingTimer = _pendingAuthorityRefreshTimers[terminalId];
    if (existingTimer != null && existingTimer.isActive) {
      AppLogger.info(
        '$_terminalStreamTraceTag coalesce authority refresh terminalId=$terminalId reason=$reason generation=${authority.historyGeneration} layoutEpoch=${authority.layoutEpoch}',
      );
      return;
    }
    AppLogger.info(
      '$_terminalStreamTraceTag schedule authority refresh terminalId=$terminalId reason=$reason generation=${authority.historyGeneration} layoutEpoch=${authority.layoutEpoch}',
    );
    _pendingAuthorityRefreshTimers[terminalId] = Timer(
      _terminalAuthorityRefreshInterval,
      () => _flushScheduledAuthorityRefresh(terminalId),
    );
  }

  void _flushScheduledAuthorityRefresh(String terminalId) {
    _pendingAuthorityRefreshTimers.remove(terminalId)?.cancel();
    final pending = _pendingAuthorityRefreshes.remove(terminalId);
    if (pending == null) {
      return;
    }
    AppLogger.info(
      '$_terminalStreamTraceTag flush authority refresh terminalId=$terminalId reason=${pending.reason} generation=${pending.generation} layoutEpoch=${pending.layoutEpoch} bufferEpoch=${pending.bufferEpoch}',
    );
    _rebuildTerminalFromAuthorityHistory(
      terminalId,
      reason: pending.reason,
    );
  }

  void _scheduleVisibleScreenSnapshotApply(
    String terminalId, {
    required String reason,
    required Map<String, dynamic> body,
    required String signature,
  }) {
    final authority = _terminalAuthorities[terminalId];
    if (authority == null) {
      return;
    }
    final existingPending = _pendingVisibleSnapshotApplies[terminalId];
    if (existingPending != null &&
        existingPending.signature == signature &&
        existingPending.bufferEpoch == authority.bufferEpoch &&
        existingPending.layoutEpoch == authority.layoutEpoch) {
      AppLogger.trace(
        '$_terminalStreamTraceTag ignore duplicate pending visible snapshot terminalId=$terminalId reason=$reason bufferEpoch=${authority.bufferEpoch} layoutEpoch=${authority.layoutEpoch}',
      );
      return;
    }
    _pendingVisibleSnapshotApplies[terminalId] = _PendingScreenSnapshotApply(
      reason: reason,
      body: body,
      signature: signature,
      bufferEpoch: authority.bufferEpoch,
      layoutEpoch: authority.layoutEpoch,
    );
    final existingTimer = _pendingVisibleSnapshotTimers[terminalId];
    if (existingTimer != null) {
      existingTimer.cancel();
      AppLogger.info(
        '$_terminalStreamTraceTag reschedule visible snapshot apply terminalId=$terminalId reason=$reason bufferEpoch=${authority.bufferEpoch} layoutEpoch=${authority.layoutEpoch}',
      );
    } else {
      AppLogger.info(
        '$_terminalStreamTraceTag schedule visible snapshot apply terminalId=$terminalId reason=$reason bufferEpoch=${authority.bufferEpoch} layoutEpoch=${authority.layoutEpoch}',
      );
    }
    _pendingVisibleSnapshotTimers[terminalId] = Timer(
      _terminalVisibleSnapshotApplyInterval,
      () => _flushVisibleScreenSnapshotApply(terminalId),
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
    final screenBytes = _decodeScreenSnapshotBytes(body);
    if (screenBytes != null) {
      _replaceTerminalSnapshot(
        terminalId: terminalId,
        bytes: screenBytes,
        streamSequence: null,
        source: 'screen',
      );
      return;
    }
    final screenLines = (body['screen_lines'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TerminalAuthorityLine.fromJson)
        .toList(growable: false);
    _replaceTerminalScreenSnapshot(
      terminalId: terminalId,
      screenLines: screenLines,
      cursorRow: (body['cursor_row'] as num?)?.toInt() ?? 0,
      cursorCol: (body['cursor_col'] as num?)?.toInt() ?? 0,
    );
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
    final transcript = authority.buildTranscript();
    if (transcript.isEmpty) {
      return false;
    }
    final streamState = _streamStateFor(terminalId);
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

  void _applyAuthorityViewportIfNeeded(String terminalId, Terminal terminal) {
    final authority = _terminalAuthorities[terminalId];
    if (authority == null || authority.cols <= 0 || authority.rows <= 0) {
      return;
    }

    final viewerRows = _preferredViewportRowsForTerminal(terminalId);
    final targetRows = authority.shouldPreferScreenSnapshotResync
        ? authority.rows
        : viewerRows > 0
            ? authority.rows.clamp(1, viewerRows)
            : authority.rows;

    if (terminal.viewWidth == authority.cols && terminal.viewHeight == targetRows) {
      return;
    }

    // 共享终端必须锁定 authority 列宽，避免不同客户端各自按本地窗口重排。
    // 但行高若也强制绑定成远端完整 rows（例如系统终端 76 行，而 Desktop
    // 面板只有 25 行），Flutter 端会把可见内容裁到屏幕顶部，表现为“闪一下
    // 然后内容消失/看起来空白”。因此这里采用“authority cols + viewer rows”
    // 的折中策略：宽度保持权威，行数受本地可视区约束，保证当前屏幕至少能
    // 稳定落在用户可见区域内。
    //
    // 已知遗留问题（暂时搁置，后续单独处理）：
    // - Desktop App 当前命令行“应该显示的当前行”定位仍然可能不准确。
    //   这和 authority rows、viewer rows、screen snapshot apply 的混合策略
    //   仍然存在偏差有关；本次提交先优先保证多端共享的基本稳定性，不在这里
    //   继续做更高风险的 cursor/viewport 语义重构。
    final viewportSource = _lastDispatchedResizeByTerminal.containsKey(terminalId)
        ? 'terminal'
        : _lastObservedViewportSize != null
            ? 'global'
            : 'unknown';
    final viewportMode = authority.shouldPreferScreenSnapshotResync
        ? 'authority_full_rows'
        : 'authority_cols_viewer_rows';
    AppLogger.info(
      '$_terminalStreamTraceTag apply authority viewport terminalId=$terminalId authority=${authority.cols}x${authority.rows} viewerRows=$viewerRows viewportSource=$viewportSource viewportMode=$viewportMode target=${authority.cols}x$targetRows current=${terminal.viewWidth}x${terminal.viewHeight}',
    );
    terminal.resize(authority.cols, targetRows);
  }

  int _preferredViewportRowsForTerminal(String terminalId) {
    final dispatched = _lastDispatchedResizeByTerminal[terminalId];
    if (dispatched != null && dispatched.rows > 0) {
      return dispatched.rows;
    }
    if (_lastObservedViewportSize != null && _lastObservedViewportSize!.rows > 0) {
      return _lastObservedViewportSize!.rows;
    }
    return 0;
  }

  void _pruneTerminalCache(Iterable<String> terminalIds) {
    final allowed = terminalIds.toSet();
    final removed = _terminalCache.keys
        .where((terminalId) => !allowed.contains(terminalId))
        .toList(growable: false);
    for (final terminalId in removed) {
      _disposeCachedTerminal(terminalId);
    }
  }

  void _resetTerminalSnapshot(Terminal terminal) {
    terminal.mainBuffer.clear();
    terminal.altBuffer.clear();
    terminal.setCursor(0, 0);
  }

  void _disposeCachedTerminal(String terminalId) {
    _autoCreatedTerminalIds.remove(terminalId);
    final terminal = _terminalCache.remove(terminalId);
    _terminalStreams.remove(terminalId);
    _terminalAuthorities.remove(terminalId);
    _viewerPresenceEpochByTerminal.remove(terminalId);
    _pendingHistoryRangesByTerminal.remove(terminalId);
    _lastDispatchedResizeByTerminal.remove(terminalId);
    _pendingAuthorityRefreshes.remove(terminalId);
    _pendingAuthorityRefreshTimers.remove(terminalId)?.cancel();
    _pendingVisibleSnapshotApplies.remove(terminalId);
    _pendingVisibleSnapshotTimers.remove(terminalId)?.cancel();
    if (terminal == null) {
      return;
    }

    // xterm does not expose a full dispose API, so detach callbacks and clear
    // buffers before dropping the cached instance.
    terminal.onOutput = null;
    terminal.onResize = null;
    terminal.onBell = null;
    terminal.onTitleChange = null;
    terminal.onIconChange = null;
    terminal.onPrivateOSC = null;
    terminal.listeners.clear();
    terminal.mainBuffer.clear();
    terminal.altBuffer.clear();
  }

  TerminalAuthorityCache _authorityCacheFor(String terminalId) {
    return _terminalAuthorities.putIfAbsent(terminalId, TerminalAuthorityCache.new);
  }

  Future<void> _detachChannel() async {
    _flushPendingOutboundOperations();

    if (_transport == _TerminalTransport.sessionWebrtc) {
      _transport = null;
      return;
    }

    final channel = _channel;
    final subscription = _channelSubscription;
    _channel = null;
    _transport = null;
    _channelSubscription = null;
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
    for (final timer in _pendingVisibleSnapshotTimers.values) {
      timer.cancel();
    }
    _pendingVisibleSnapshotTimers.clear();
    _pendingVisibleSnapshotApplies.clear();
  }

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
    _authorityCacheFor(terminalId).applyStateSnapshot(body);
  }

  void _handleTerminalScreenSnapshot(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    final authority = _authorityCacheFor(terminalId);
    authority.applyScreenSnapshot(body);
    final streamState = _streamStateFor(terminalId);
    final shouldForceViewportResync = streamState.shouldForceViewportResync(
      bufferEpoch: authority.bufferEpoch,
      layoutEpoch: authority.layoutEpoch,
    );
    final preferScreenSnapshotResync = authority.shouldPreferScreenSnapshotResync;
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
    if (!streamState.acceptsViewportResync && !shouldForceViewportResync) {
      // 这里的 screen snapshot 只有“当前屏幕视口”，不包含完整 scrollback。
      // 一旦终端已经进入正常交互态，再用它整屏 replace 会把 xterm 已积累的
      // 历史缓冲区清掉，表现为“历史突然丢失”。因此首帧 bootstrap 允许应用，
      // 后续仅缓存 authority 元数据，不再拿 viewport snapshot 覆盖整条历史。
      streamState.markAppliedScreenSnapshot(
        signature: snapshotSignature,
        bufferEpoch: authority.bufferEpoch,
        layoutEpoch: authority.layoutEpoch,
        rows: authority.rows,
        cols: authority.cols,
      );
      AppLogger.info(
        '$_terminalStreamTraceTag skip screen snapshot replace terminalId=$terminalId bufferEpoch=${authority.bufferEpoch} layoutEpoch=${authority.layoutEpoch} preserveHistory=true',
      );
      return;
    }
    if (shouldForceViewportResync) {
      if (preferScreenSnapshotResync) {
        _scheduleVisibleScreenSnapshotApply(
          terminalId,
          reason: 'visible_history_only',
          body: body,
          signature: snapshotSignature,
        );
        streamState.markAppliedScreenSnapshot(
          signature: snapshotSignature,
          bufferEpoch: authority.bufferEpoch,
          layoutEpoch: authority.layoutEpoch,
          rows: authority.rows,
          cols: authority.cols,
        );
        streamState.markInteractiveFrame();
        return;
      }
      AppLogger.info(
        '$_terminalStreamTraceTag force screen snapshot replace terminalId=$terminalId bufferEpoch=${authority.bufferEpoch} layoutEpoch=${authority.layoutEpoch}',
      );
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
        reason: 'force_viewport_resync',
      );
      return;
    }
    final screenBytes = _decodeScreenSnapshotBytes(body);
    if (screenBytes != null) {
      _replaceTerminalSnapshot(
        terminalId: terminalId,
        bytes: screenBytes,
        streamSequence: null,
        source: 'screen',
      );
      streamState.markAppliedScreenSnapshot(
        signature: snapshotSignature,
        bufferEpoch: authority.bufferEpoch,
        layoutEpoch: authority.layoutEpoch,
        rows: authority.rows,
        cols: authority.cols,
      );
      streamState.markInteractiveFrame();
      return;
    }
    final screenLines = (body['screen_lines'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TerminalAuthorityLine.fromJson)
        .toList(growable: false);
    _replaceTerminalScreenSnapshot(
      terminalId: terminalId,
      screenLines: screenLines,
      cursorRow: (body['cursor_row'] as num?)?.toInt() ?? 0,
      cursorCol: (body['cursor_col'] as num?)?.toInt() ?? 0,
    );
    streamState.markAppliedScreenSnapshot(
      signature: snapshotSignature,
      bufferEpoch: authority.bufferEpoch,
      layoutEpoch: authority.layoutEpoch,
      rows: authority.rows,
      cols: authority.cols,
    );
    streamState.markInteractiveFrame();
  }

  void _handleTerminalHistoryAppend(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    _authorityCacheFor(terminalId).appendHistory(body);
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
  }

  void _handleTerminalBufferChanged(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    _authorityCacheFor(terminalId).applyBufferChanged(body);
  }

  void _handleTerminalScrollbackTrimmed(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }
    _authorityCacheFor(terminalId).applyTrimmed(body);
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
    final previewLineCount = (previewEndLine - previewStartLine).clamp(0, _terminalAuthorityCacheMaxLines);
    final desiredStartLine = (previewStartLine - (_terminalAuthorityCacheMaxLines - previewLineCount)).clamp(
      authority.historyStartLine,
      previewStartLine,
    );
    final cacheSize = authority.historyLines.length;
    AppLogger.info(
      '$_terminalStreamTraceTag history invalidated terminalId=$terminalId generation=${authority.historyGeneration} history=${authority.historyStartLine}-${authority.historyEndLine} preview=$previewStartLine-$previewEndLine previewLines=$previewLineCount desiredStart=$desiredStartLine cacheSize=$cacheSize',
    );
    if (authority.shouldPreferScreenSnapshotResync) {
      AppLogger.info(
        '$_terminalStreamTraceTag skip authority refresh schedule terminalId=$terminalId reason=visible_history_only',
      );
      return;
    }
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

  String? _resolveEventTerminalId(Map<String, dynamic> body) {
    return body['terminal_id'] as String? ?? state.activeTerminalId;
  }

  List<int>? _decodeEventBytes(Map<String, dynamic> body) {
    final data = body['data_base64'] as String?;
    if (data == null) {
      return null;
    }

    return base64Decode(data);
  }

  List<int>? _decodeScreenSnapshotBytes(Map<String, dynamic> body) {
    final data = body['screen_data_base64'] as String?;
    if (data == null || data.isEmpty) {
      return null;
    }
    return base64Decode(data);
  }

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

  void _handleTerminalReady(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body) ?? '';
    if (terminalId.isEmpty) {
      return;
    }
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

  void _removeApprovalRequest({
    required String requestId,
    required String aiSessionId,
    required String agentId,
    required String capabilityKey,
  }) {
    state = state.copyWith(
      pendingApprovalRequests: state.pendingApprovalRequests
          .where(
            (request) {
              if (requestId.trim().isNotEmpty &&
                  request.requestId != null &&
                  request.requestId == requestId) {
                return false;
              }
              return !(request.aiSessionId == aiSessionId &&
                  request.agentId == agentId &&
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

  bool get _shouldAutoCreateDefaultTerminal {
    if (_config.deviceId == null) {
      return false;
    }

    // Only the desktop-local terminal workspace should synthesize a default tab.
    return _shouldUseDesktopLocalTransport && _config.sessionId == null;
  }

  bool get _shouldWaitForRemoteSession {
    return !_shouldUseDesktopLocalTransport &&
        _config.deviceId == null &&
        _config.sessionId == null;
  }

  bool get _shouldWaitForSessionTransport {
    return !_shouldUseDesktopLocalTransport &&
        _config.sessionId != null &&
        !_shouldUseSessionTransport;
  }

  bool get _shouldUseSessionTransport {
    final sessionId = _config.sessionId;
    if (sessionId == null || _shouldUseDesktopLocalTransport) {
      return false;
    }

    return _sessionTerminalChannelController.isReadyForSession(sessionId);
  }

  bool get _shouldUseDesktopLocalTransport {
    if (_desktopLocalClient == null || kIsWeb) {
      return false;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  int get _preferredCols {
    final cols = state.activeTerminal?.cols ?? 120;
    return cols.clamp(20, 400);
  }

  int get _preferredRows {
    final rows = state.activeTerminal?.rows ?? 32;
    return rows.clamp(10, 200);
  }

  bool _shouldFlushInputImmediately(String data) {
    return data.length >= _terminalImmediateInputThreshold ||
        data.contains('\n') ||
        data.contains('\r') ||
        _containsImmediateControlInput(data);
  }

  bool _containsImmediateControlInput(String data) {
    // Terminal control keys such as ESC, Ctrl+C and arrow-key escape
    // sequences should bypass the small debounce window. Delaying these bytes
    // makes interruption-oriented interactions feel unreliable, especially for
    // Sirix/Codex-style TUI flows that expect `Esc` to cancel the current job
    // immediately.
    for (final codeUnit in data.codeUnits) {
      final isAsciiControl = codeUnit < 0x20 || codeUnit == 0x7f;
      if (isAsciiControl && codeUnit != 0x0a && codeUnit != 0x0d) {
        return true;
      }
    }
    return false;
  }

  void _handleTerminalPrivateOsc({
    required String terminalId,
    required String code,
    required List<String> args,
  }) {
    if (args.isEmpty || args.first != '?') {
      return;
    }

    final rgb = switch (code) {
      '10' => _terminalOscColorPayload(TerminalThemes.defaultTheme.foreground),
      '11' => _terminalOscColorPayload(TerminalThemes.defaultTheme.background),
      _ => null,
    };
    if (rgb == null) {
      return;
    }

    AppLogger.info(
      '$_terminalOscTraceTag respond terminalId=$terminalId slot=$code color=$rgb',
    );
    _sendImmediateTerminalInput(
      terminalId: terminalId,
      data: '\x1b]$code;$rgb\x1b\\',
    );
  }

  String _terminalOscColorPayload(Color color) {
    int to16Bit(int value) => value * 257;
    int channel(double value) => (value * 255.0).round() & 0xff;
    final r = to16Bit(channel(color.r)).toRadixString(16).padLeft(4, '0');
    final g = to16Bit(channel(color.g)).toRadixString(16).padLeft(4, '0');
    final b = to16Bit(channel(color.b)).toRadixString(16).padLeft(4, '0');
    return 'rgb:$r/$g/$b';
  }

  void _flushPendingInput() {
    _inputTimer?.cancel();
    _inputTimer = null;

    final pendingInput = _pendingInput;
    _pendingInput = null;
    final data = pendingInput?.buffer.toString() ?? '';
    if (data.isEmpty || pendingInput == null) {
      return;
    }

    final payload = base64Encode(utf8.encode(data));
    _sendTerminalInputPayload(
      terminalId: pendingInput.terminalId,
      payload: payload,
    );
  }

  void _sendImmediateTerminalInput({
    required String terminalId,
    required String data,
  }) {
    if (data.isEmpty) {
      return;
    }
    final payload = base64Encode(utf8.encode(data));
    _sendTerminalInputPayload(
      terminalId: terminalId,
      payload: payload,
    );
  }

  void _sendTerminalInputPayload({
    required String terminalId,
    required String payload,
  }) {
    if (_transport == _TerminalTransport.sessionWebrtc) {
      unawaited(_sessionTerminalChannelController.sendJson({
        'type': 'terminal.input',
        'terminal_id': terminalId,
        'data_base64': payload,
      }));
      return;
    }

    final channel = _channel;
    if (channel == null) {
      return;
    }

    if (_transport == _TerminalTransport.desktopLocal) {
      _desktopLocalClient?.sendTerminalInput(
        channel: channel,
        terminalId: terminalId,
        dataBase64: payload,
      );
      return;
    }

    channel.sink.add(
      jsonEncode({
        'type': 'terminal.input',
        'data_base64': payload,
      }),
    );
  }

  void _flushPendingResizeAtTrailingEdge() {
    _resizeTimer = null;
    _resizeTrailingWindowActive = false;
    if (_pendingResize != null) {
      AppLogger.info(
        '$_terminalStreamTraceTag trailing resize terminalId=${_pendingResize!.terminalId} cols=${_pendingResize!.cols} rows=${_pendingResize!.rows}',
      );
    }
    _flushPendingResize();
  }

  void _flushPendingResize() {
    _resizeTimer?.cancel();
    _resizeTimer = null;

    final resize = _pendingResize;
    _pendingResize = null;
    if (resize == null) {
      return;
    }

    if (_shouldUseAuthorityViewportSizing &&
        _transport == _TerminalTransport.sessionWebrtc) {
      AppLogger.info(
        '$_terminalStreamTraceTag ignore viewer resize terminalId=${resize.terminalId} cols=${resize.cols} rows=${resize.rows} reason=authority_viewport',
      );
      return;
    }

    if (_shouldOptimisticallyUpdateSummaryForResize(resize.terminalId)) {
      _scheduleTerminalViewportSummaryUpdate(
        terminalId: resize.terminalId,
        cols: resize.cols,
        rows: resize.rows,
      );
    } else {
      AppLogger.info(
        '$_terminalStreamTraceTag keep authority summary terminalId=${resize.terminalId} cols=${resize.cols} rows=${resize.rows} authority=${_terminalAuthorities[resize.terminalId]?.authoritySource ?? 'unknown'}',
      );
    }
    final viewportSize = _TerminalViewportSize(
      cols: resize.cols,
      rows: resize.rows,
    );
    _lastObservedViewportSize = viewportSize;
    _lastDispatchedResizeByTerminal[resize.terminalId] = viewportSize;

    final authoritySource =
        _terminalAuthorities[resize.terminalId]?.authoritySource ?? 'unknown';
    final viewerPresenceEpoch = _viewerPresenceEpochByTerminal[resize.terminalId];

    if (_transport == _TerminalTransport.desktopLocal &&
        authoritySource == 'system_terminal') {
      // 当系统终端仍是 PTY 几何权威时，Desktop App 的 viewer resize 只应该
      // 更新本地可视区缓存，不能再把自己的列数回写到 desktop-server。
      // 否则 render -> onResize -> local ws resize 会形成无意义的几何抖动，
      // 表现为拖动停止后仍持续 refresh。
      AppLogger.info(
        '$_terminalStreamTraceTag ignore viewer resize terminalId=${resize.terminalId} cols=${resize.cols} rows=${resize.rows} reason=system_terminal_authority',
      );
      return;
    }

    if (_transport == _TerminalTransport.sessionWebrtc) {
      unawaited(_sessionTerminalChannelController.sendJson({
        'type': 'terminal.resize',
        'terminal_id': resize.terminalId,
        'cols': resize.cols,
        'rows': resize.rows,
        'client_kind': 'mobile_app',
        'viewer_presence_epoch': viewerPresenceEpoch,
      }));
      return;
    }

    final channel = _channel;
    if (_transport == _TerminalTransport.desktopLocal) {
      if (channel == null) {
        return;
      }
      _desktopLocalClient?.sendTerminalResize(
        channel: channel,
        terminalId: resize.terminalId,
        cols: resize.cols,
        rows: resize.rows,
        clientKind: 'desktop_app',
        viewerPresenceEpoch: viewerPresenceEpoch,
      );
      return;
    }

    if (channel == null) {
      return;
    }

    channel.sink.add(
      jsonEncode({
        'type': 'terminal.resize',
        'cols': resize.cols,
        'rows': resize.rows,
        'client_kind': 'desktop_app',
        'viewer_presence_epoch': viewerPresenceEpoch,
      }),
    );
  }

  bool get _shouldUseMobileResizeCoalescing {
    if (kIsWeb) {
      return false;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  bool get _shouldUseAuthorityViewportSizing => _config.sessionId != null;

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
      final sent = await _sessionTerminalChannelController.sendJson({
        'type': 'terminal.history.range.request',
        'payload': {
          'request_id': requestId,
          'terminal_id': terminalId,
          'history_generation': generation,
          'start_line': startLine,
          'end_line': endLine,
        },
      });
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
      jsonEncode({
        'type': 'terminal.history.range.request',
        'payload': {
          'request_id': requestId,
          'terminal_id': terminalId,
          'history_generation': generation,
          'start_line': startLine,
          'end_line': endLine,
        },
      }),
    );
  }

  void onTerminalVerticalScroll({
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

  @override
  void dispose() {
    _disposed = true;
    unawaited(_detachChannel());
    unawaited(_sessionChannelSubscription?.cancel());
    final cachedTerminalIds = _terminalCache.keys.toList(growable: false);
    for (final terminalId in cachedTerminalIds) {
      _disposeCachedTerminal(terminalId);
    }
    super.dispose();
  }

  void onSessionTerminalChannelStateChanged(
    SessionTerminalChannelState? previous,
    SessionTerminalChannelState next,
  ) {
    final sessionId = _config.sessionId;
    if (sessionId == null || next.sessionId != sessionId) {
      return;
    }

    final becameReady = next.ready && (previous?.ready ?? false) != true;
    if (becameReady) {
      Future.microtask(() => load(force: true));
      return;
    }

    final becameUnavailable = !next.ready && (previous?.ready ?? false);
    if (becameUnavailable && _transport == _TerminalTransport.sessionWebrtc) {
      state = state.copyWith(connecting: false);
    }
  }

  Future<WebSocketChannel> _connectDesktopLocalChannel() async {
    if (_channel != null && _transport == _TerminalTransport.desktopLocal) {
      return _channel!;
    }

    final localClient = _desktopLocalClient;
    if (localClient == null) {
      throw StateError('desktop local client unavailable');
    }

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
        state = state.copyWith(connecting: false);
      },
    );
    return channel;
  }
}

final terminalViewModelProvider =
    StateNotifierProvider.family<TerminalViewModel, TerminalState, TerminalPageConfig>((
  ref,
  config,
) {
  final apiClient = ref.watch(backendApiClientProvider);
  final eventClient = ref.watch(backendEventClientProvider);
  final desktopLocalClient = ref.watch(desktopLocalClientProvider);
  final sessionTerminalChannelController = ref.watch(
    sessionTerminalChannelControllerProvider.notifier,
  );
  final viewModel = TerminalViewModel(
    apiClient: apiClient,
    eventClient: eventClient,
    desktopLocalClient: desktopLocalClient,
    sessionTerminalChannelController: sessionTerminalChannelController,
    config: config,
  );
  ref.listen<SessionTerminalChannelState>(
    sessionTerminalChannelControllerProvider,
    (previous, next) {
      viewModel.onSessionTerminalChannelStateChanged(previous, next);
    },
  );
  return viewModel;
});

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
  String? _lastScreenSnapshotSignature;
  int? _lastScreenBufferEpoch;
  int? _lastScreenLayoutEpoch;
  int? _lastScreenRows;
  int? _lastScreenCols;
  final List<int> _pendingUtf8Bytes = <int>[];

  void prepareForAttach() {
    hasInteractiveFrame = false;
    awaitingViewportBootstrap = true;
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

  bool get shouldPreferScreenSnapshotResync {
    if (rows <= 0) {
      return false;
    }
    if (activeBuffer != 'main') {
      return true;
    }
    final historyLineCount = historyEndLine - historyStartLine;
    final viewportLineCount = viewportEndLine - viewportStartLine;
    // 当 history 规模没有超出当前 viewport 时，authority 并没有提供可供
    // “重建滚动历史”的额外信息，此时更接近全屏 UI / TUI 的当前屏幕镜像。
    // 继续用 transcript 重建会丢失定位与空白布局，导致和系统终端不对齐。
    return historyLineCount <= rows && viewportLineCount <= rows;
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
    return [
      (json['history_generation'] as num?)?.toInt() ?? -1,
      (json['history_start_line'] as num?)?.toInt() ?? -1,
      (json['history_end_line'] as num?)?.toInt() ?? -1,
      (json['start_line'] as num?)?.toInt() ?? -1,
      (json['end_line'] as num?)?.toInt() ?? -1,
      json['reason'] as String? ?? '',
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
