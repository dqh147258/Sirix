import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

import 'terminal_state.dart';

const Duration _terminalInputDebounce = Duration(milliseconds: 12);
const Duration _terminalResizeDebounce = Duration(milliseconds: 80);
const Duration _terminalSessionAttachRetryDelay = Duration(milliseconds: 180);
const int _terminalImmediateInputThreshold = 128;
const int _terminalSessionAttachRetryCount = 6;

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

enum TerminalUiEventType {
  snapshot,
  output,
  approvalRequested,
}

@immutable
class TerminalUiEvent {
  const TerminalUiEvent.snapshot({
    required this.terminalId,
    required this.text,
  }) : type = TerminalUiEventType.snapshot;

  const TerminalUiEvent.output({
    required this.terminalId,
    required this.text,
  }) : type = TerminalUiEventType.output;

  const TerminalUiEvent.approvalRequested({
    required this.terminalId,
    required this.text,
  }) : type = TerminalUiEventType.approvalRequested;

  final TerminalUiEventType type;
  final String terminalId;
  final String text;
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
  final TerminalPageConfig _config;
  final StreamController<TerminalUiEvent> _events =
      StreamController<TerminalUiEvent>.broadcast();

  WebSocketChannel? _channel;
  _TerminalTransport? _transport;
  StreamSubscription<dynamic>? _channelSubscription;
  StreamSubscription<Map<String, dynamic>>? _sessionChannelSubscription;
  Timer? _inputTimer;
  Timer? _resizeTimer;
  _QueuedInput? _pendingInput;
  _QueuedResize? _pendingResize;
  Completer<List<TerminalSessionSummary>>? _pendingSessionTerminalListCompleter;
  bool _hasLoaded = false;
  bool _loadingInFlight = false;
  bool _creatingInFlight = false;

  Stream<TerminalUiEvent> get events => _events.stream;

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

    final completer = Completer<List<TerminalSessionSummary>>();
    _pendingSessionTerminalListCompleter = completer;

    final sent = await _sessionTerminalChannelController.sendJson({
      'type': 'terminal.list',
    });
    if (!sent) {
      _pendingSessionTerminalListCompleter = null;
      AppLogger.warn('session terminal list request skipped: data channel unavailable');
      return const [];
    }

    try {
      return await completer.future.timeout(const Duration(milliseconds: 1500));
    } on TimeoutException {
      if (identical(_pendingSessionTerminalListCompleter, completer)) {
        _pendingSessionTerminalListCompleter = null;
      }
      AppLogger.warn('session terminal list timed out');
      return const [];
    }
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

    if (_shouldUseSessionTransport) {
      await _detachChannel();
      _transport = _TerminalTransport.sessionWebrtc;
      final sent = await _sessionTerminalChannelController.sendJson({
        'type': 'terminal.attach',
        'terminal_id': terminalId,
      });
      if (sent) {
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
        _desktopLocalClient!.sendTerminalAttach(
          channel: channel,
          terminalId: terminalId,
        );
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

    _pendingResize = _QueuedResize(
      terminalId: terminalId,
      cols: cols,
      rows: rows,
    );

    _resizeTimer?.cancel();
    _resizeTimer = Timer(_terminalResizeDebounce, _flushPendingResize);
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
    final text = _decodeEventText(body);
    if (terminalId == null || text == null) {
      return;
    }

    _events.add(TerminalUiEvent.output(
      terminalId: terminalId,
      text: text,
    ));
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
    final text = _decodeEventText(body);
    if (terminalId == null) {
      return;
    }

    _events.add(TerminalUiEvent.snapshot(
      terminalId: terminalId,
      text: text ?? '',
    ));
  }

  void _handleTerminalClosed(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body);
    if (terminalId == null) {
      return;
    }

    _removeTerminalById(terminalId);
    _events.add(TerminalUiEvent.output(
      terminalId: terminalId,
      text: '\r\n[terminal closed]\r\n',
    ));
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
    _events.add(TerminalUiEvent.output(
      terminalId: terminalId,
      text: '\r\n[terminal error] $message\r\n',
    ));
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
      capabilityKey: capabilityKey,
      agentId: body['agent_id'] as String? ?? '',
      modelId: body['model_id'] as String? ?? '',
      cwd: body['cwd'] as String? ?? '',
      configuredMode: approvalModeFromJson(body['configured_mode'] as String?),
    );
    if (state.pendingApprovalRequests.any((item) => item.dedupeKey == request.dedupeKey)) {
      return;
    }

    state = state.copyWith(
      pendingApprovalRequests: [...state.pendingApprovalRequests, request],
      clearError: true,
    );
    _events.add(TerminalUiEvent.approvalRequested(
      terminalId: terminalId,
      text: capabilityKey,
    ));
  }

  void _handleApprovalResolved(Map<String, dynamic> body) {
    final aiSessionId = body['ai_session_id'] as String? ?? '';
    final capabilityKey = body['capability_key'] as String? ?? '';
    if (aiSessionId.isEmpty || capabilityKey.isEmpty) {
      return;
    }
    _removeApprovalRequest(aiSessionId: aiSessionId, capabilityKey: capabilityKey);
  }

  String? _resolveEventTerminalId(Map<String, dynamic> body) {
    return body['terminal_id'] as String? ?? state.activeTerminalId;
  }

  String? _decodeEventText(Map<String, dynamic> body) {
    final data = body['data_base64'] as String?;
    if (data == null) {
      return null;
    }

    final bytes = base64Decode(data);
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }

  void _handleTerminalReady(Map<String, dynamic> body) {
    final terminalId = _resolveEventTerminalId(body) ?? '';
    if (terminalId.isEmpty) {
      return;
    }

    _upsertTerminalSummary(_terminalSummaryFromEvent(body));
  }

  void _replaceTerminals(List<TerminalSessionSummary> terminals) {
    final currentActive = state.activeTerminalId;
    final hasCurrent = currentActive != null &&
        terminals.any((terminal) => terminal.id == currentActive);
    state = state.copyWith(
      terminals: terminals,
      pendingApprovalRequests: state.pendingApprovalRequests
          .where((request) => terminals.any((terminal) => terminal.id == request.terminalId))
          .toList(growable: false),
      activeTerminalId: hasCurrent ? currentActive : null,
      clearActiveTerminalId: !hasCurrent,
    );
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
    state = state.copyWith(
      terminals: remaining,
      pendingApprovalRequests: state.pendingApprovalRequests
          .where((request) => request.terminalId != terminalId)
          .toList(growable: false),
      activeTerminalId: nextActiveId,
      clearActiveTerminalId: closingActive && nextActiveId == null,
    );
  }

  Future<void> resolveApprovalRequest({
    required TerminalApprovalRequest request,
    required String decision,
    required String scope,
  }) async {
    final localClient = _desktopLocalClient;
    if (localClient == null) {
      state = state.copyWith(
        errorMessage: 'Desktop local approval channel unavailable.',
      );
      return;
    }

    try {
      await localClient.resolveAiApproval(
        sessionId: request.aiSessionId,
        capabilityKey: request.capabilityKey,
        decision: decision,
        scope: scope,
      );
      _removeApprovalRequest(
        aiSessionId: request.aiSessionId,
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
    required String aiSessionId,
    required String capabilityKey,
  }) {
    state = state.copyWith(
      pendingApprovalRequests: state.pendingApprovalRequests
          .where(
            (request) =>
                !(request.aiSessionId == aiSessionId &&
                    request.capabilityKey == capabilityKey),
          )
          .toList(growable: false),
    );
  }

  bool _shouldRetrySessionAttach(String terminalId) {
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
        'terminal_id': terminalId,
      });
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
        data.contains('\r');
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
    if (_transport == _TerminalTransport.sessionWebrtc) {
      unawaited(_sessionTerminalChannelController.sendJson({
        'type': 'terminal.input',
        'terminal_id': pendingInput.terminalId,
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
        terminalId: pendingInput.terminalId,
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

  void _flushPendingResize() {
    _resizeTimer?.cancel();
    _resizeTimer = null;

    final resize = _pendingResize;
    _pendingResize = null;
    if (resize == null) {
      return;
    }

    _updateTerminalSummary(
      resize.terminalId,
      (terminal) => terminal.copyWith(cols: resize.cols, rows: resize.rows),
    );

    if (_transport == _TerminalTransport.sessionWebrtc) {
      unawaited(_sessionTerminalChannelController.sendJson({
        'type': 'terminal.resize',
        'terminal_id': resize.terminalId,
        'cols': resize.cols,
        'rows': resize.rows,
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
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_detachChannel());
    unawaited(_sessionChannelSubscription?.cancel());
    unawaited(_events.close());
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

class _QueuedInput {
  _QueuedInput({required this.terminalId});

  final String terminalId;
  final StringBuffer buffer = StringBuffer();
}

enum _TerminalTransport {
  backend,
  desktopLocal,
  sessionWebrtc,
}
