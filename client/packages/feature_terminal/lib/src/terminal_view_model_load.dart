part of 'terminal_view_model.dart';

abstract class _TerminalViewModelLoadBase extends _TerminalViewModelEventsBBase {
  _TerminalViewModelLoadBase({
    required super.apiClient,
    required super.eventClient,
    required super.desktopLocalClient,
    required super.sessionTerminalChannelController,
    required super.config,
  });
  @override
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
      final sent = await _sessionTerminalChannelController.sendJson(
        buildTerminalCloseMessage(terminalId: terminalId),
      );
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

  @override
  Future<void> attachTerminal(
    String terminalId,
  ) async {
    if (_attachingTerminalId == terminalId) {
      AppLogger.trace(
        '$_terminalStreamTraceTag ignore duplicate attach request terminalId=$terminalId reason=attach_in_flight',
      );
      return;
    }

    final previousActiveId = state.activeTerminalId;
    final alreadyAttached = state.activeTerminalId == terminalId &&
        !state.connecting &&
        ((_transport == _TerminalTransport.sessionWebrtc && _shouldUseSessionTransport) ||
            _channel != null);
    if (alreadyAttached) {
      return;
    }

    _attachingTerminalId = terminalId;
    try {
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
      // 这里不再无条件丢掉 terminalId 自己最近一次已知 viewport。日志表明
      // desktop local ws 在重连/复用时可能会短暂先收到 bootstrap，再等到
      // RenderTerminal 的 onResize 回调；若提前把 viewer rows 清空，就会出现
      // `viewerRows=0 -> authority_full_rows` 的错误回退，导致重连后先被拉成
      // 远端完整高度，再立刻缩回当前面板高度，表现为明显闪烁和历史错位。
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
        final sent = await _sessionTerminalChannelController.sendJson(
          buildTerminalAttachMessage(
            terminalId: terminalId,
            protocolVersion: authorityTerminalProtocolVersion,
            syncMode: _terminalSyncModeV2,
            clientKind: 'mobile_app',
          ),
        );
        if (sent) {
          await _sessionTerminalChannelController.sendJson(
            buildTerminalBootstrapRequestMessage(terminalId: terminalId),
          );
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
          AppLogger.warn(
            'desktop local terminal attach failed terminalId=$terminalId error=$error',
          );
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
          jsonEncode(
            buildTerminalAttachMessage(
              terminalId: terminalId,
              protocolVersion: authorityTerminalProtocolVersion,
              syncMode: _terminalSyncModeV2,
              clientKind: _shouldUseSessionTransport ? 'mobile_app' : 'desktop_app',
            ),
          ),
        );
        channel.sink.add(
          jsonEncode(
            buildTerminalBootstrapRequestMessage(terminalId: terminalId),
          ),
        );
        state = state.copyWith(connecting: false);
      } catch (error) {
        state = state.copyWith(
          connecting: false,
          errorMessage: AppLocalizations.current.terminalConnectFailed('$error'),
        );
      }
    } finally {
      if (_attachingTerminalId == terminalId) {
        _attachingTerminalId = null;
      }
    }
  }
}
