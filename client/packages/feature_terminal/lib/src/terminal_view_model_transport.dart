part of 'terminal_view_model.dart';

abstract class _TerminalViewModelTransportBase extends _TerminalViewModelStateBase {
  _TerminalViewModelTransportBase({
    required super.apiClient,
    required super.eventClient,
    required super.desktopLocalClient,
    required super.sessionTerminalChannelController,
    required super.config,
  });

  bool _shouldOptimisticallyUpdateSummaryForResize(String terminalId);
  void _updateTerminalSummary(
    String terminalId,
    TerminalSessionSummary Function(TerminalSessionSummary terminal) updater,
  );
  Future<void> _detachChannel();
  void _disposeCachedTerminal(String terminalId);
  void _handleSocketEvent(WebSocketChannel channel, dynamic raw);
  Future<void> load({bool force = false});

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

  void onTerminalVerticalScroll({
    required String terminalId,
    required double extentBefore,
  }) {
    _handleTerminalVerticalScroll(
      terminalId: terminalId,
      extentBefore: extentBefore,
    );
  }

  @override
  void _disposeInternal() {
    _disposed = true;
    unawaited(_detachChannel());
    unawaited(_sessionChannelSubscription?.cancel());
    final cachedTerminalIds = _terminalCache.keys.toList(growable: false);
    for (final terminalId in cachedTerminalIds) {
      _disposeCachedTerminal(terminalId);
    }
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
}
