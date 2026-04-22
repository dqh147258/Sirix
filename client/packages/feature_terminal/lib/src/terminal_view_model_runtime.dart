part of 'terminal_view_model.dart';

abstract class _TerminalViewModelRuntimeBase extends _TerminalViewModelTransportBase {
  _TerminalViewModelRuntimeBase({
    required super.apiClient,
    required super.eventClient,
    required super.desktopLocalClient,
    required super.sessionTerminalChannelController,
    required super.config,
  });

  List<int>? _decodeScreenSnapshotBytes(Map<String, dynamic> body);

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

  @override
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

  void _applyAuthorityViewportIfNeeded(
    String terminalId,
    Terminal terminal, {
    int? visibleRowOverride,
  }) {
    final authority = _terminalAuthorities[terminalId];
    if (authority == null || authority.cols <= 0 || authority.rows <= 0) {
      return;
    }

    final viewerRows = _preferredViewportRowsForTerminal(terminalId);
    final streamState = _streamStateFor(terminalId);
    final hasLockedVisibleWindow =
        streamState.initialVisibleWindowTopOffset != null && viewerRows > 0;
    final targetRows = visibleRowOverride != null && visibleRowOverride > 0
        ? visibleRowOverride
        : authority.shouldPreferScreenSnapshotResync
        ? hasLockedVisibleWindow
            ? authority.rows.clamp(1, viewerRows)
            : authority.rows
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
        ? visibleRowOverride != null && visibleRowOverride > 0
            ? 'authority_visible_window_rows'
            : hasLockedVisibleWindow
                ? 'authority_locked_visible_rows'
                : 'authority_full_rows'
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

  @override
  void _disposeCachedTerminal(String terminalId) {
    _autoCreatedTerminalIds.remove(terminalId);
    _lastReadySignaturesByTerminal.remove(terminalId);
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
}
