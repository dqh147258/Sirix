import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'terminal_state.dart';

const Duration _terminalInputDebounce = Duration(milliseconds: 12);
const Duration _terminalResizeDebounce = Duration(milliseconds: 80);
const int _terminalImmediateInputThreshold = 128;

@immutable
class TerminalPageConfig {
  const TerminalPageConfig({
    required this.accessToken,
    required this.deviceId,
    required this.allowCreate,
  });

  // UI presentation flags are intentionally excluded so every entry point
  // shares the same terminal workspace for a given authenticated device.
  final String accessToken;
  final String? deviceId;
  final bool allowCreate;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TerminalPageConfig &&
            runtimeType == other.runtimeType &&
            accessToken == other.accessToken &&
            deviceId == other.deviceId &&
            allowCreate == other.allowCreate;
  }

  @override
  int get hashCode => Object.hash(accessToken, deviceId, allowCreate);
}

enum TerminalUiEventType {
  snapshot,
  output,
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

  final TerminalUiEventType type;
  final String terminalId;
  final String text;
}

class TerminalViewModel extends BaseViewModel<TerminalState> {
  TerminalViewModel({
    required BackendApiClient apiClient,
    required BackendEventClient? eventClient,
    required DesktopLocalClient? desktopLocalClient,
    required TerminalPageConfig config,
  })  : _apiClient = apiClient,
        _eventClient = eventClient,
        _desktopLocalClient = desktopLocalClient,
        _config = config,
        super(const TerminalState());

  final BackendApiClient _apiClient;
  final BackendEventClient? _eventClient;
  final DesktopLocalClient? _desktopLocalClient;
  final TerminalPageConfig _config;
  final StreamController<TerminalUiEvent> _events =
      StreamController<TerminalUiEvent>.broadcast();

  WebSocketChannel? _channel;
  _TerminalTransport? _transport;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _inputTimer;
  Timer? _resizeTimer;
  _QueuedInput? _pendingInput;
  _QueuedResize? _pendingResize;
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

    try {
      final terminals = _shouldUseDesktopLocalTransport
          ? await _loadDesktopLocalTerminals()
          : await _apiClient.listTerminals(
              accessToken: _config.accessToken,
              deviceId: _config.deviceId,
            );
      _replaceTerminals(terminals);
      state = state.copyWith(loading: false, clearError: true);

      if (state.terminals.isEmpty) {
        if (_shouldCreateDefaultTerminal) {
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
        } else if (_shouldCreateDefaultTerminal) {
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
    final alreadyAttached =
        state.activeTerminalId == terminalId && _channel != null && !state.connecting;
    if (alreadyAttached) {
      return;
    }

    if (_transport == _TerminalTransport.desktopLocal) {
      _flushPendingOutboundOperations();
    } else {
      await _detachChannel();
    }
    state = state.copyWith(
      activeTerminalId: terminalId,
      connecting: true,
      clearError: true,
    );

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

    final type = payload['type'] as String?;
    final body = payload['payload'] as Map<String, dynamic>?;
    if (type == null || body == null) {
      return;
    }

    switch (type) {
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

    _updateTerminalStateById(terminalId, 'closed');
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

    _updateTerminalSummary(
      terminalId,
      (terminal) => terminal.copyWith(
        title: body['title'] as String?,
        shell: body['shell'] as String?,
        cwd: body['cwd'] as String?,
        state: body['state'] as String?,
        cols: body['cols'] as int?,
        rows: body['rows'] as int?,
      ),
    );
  }

  void _replaceTerminals(List<TerminalSessionSummary> terminals) {
    final currentActive = state.activeTerminalId;
    final hasCurrent = currentActive != null &&
        terminals.any((terminal) => terminal.id == currentActive);
    state = state.copyWith(
      terminals: terminals,
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

  void _updateTerminalStateById(String terminalId, String nextState) {
    _updateTerminalSummary(
      terminalId,
      (terminal) => terminal.copyWith(state: nextState),
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

  bool get _shouldCreateDefaultTerminal =>
      _config.allowCreate && _config.deviceId != null;

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

    final channel = _channel;
    if (channel == null) {
      return;
    }

    final payload = base64Encode(utf8.encode(data));
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
    final channel = _channel;
    _pendingResize = null;
    if (resize == null || channel == null) {
      return;
    }

    _updateTerminalSummary(
      resize.terminalId,
      (terminal) => terminal.copyWith(cols: resize.cols, rows: resize.rows),
    );

    if (_transport == _TerminalTransport.desktopLocal) {
      _desktopLocalClient?.sendTerminalResize(
        channel: channel,
        terminalId: resize.terminalId,
        cols: resize.cols,
        rows: resize.rows,
      );
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
    unawaited(_events.close());
    super.dispose();
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

final terminalViewModelProvider = StateNotifierProvider.autoDispose
    .family<TerminalViewModel, TerminalState, TerminalPageConfig>((ref, config) {
  final apiClient = ref.watch(backendApiClientProvider);
  final eventClient = ref.watch(backendEventClientProvider);
  final desktopLocalClient = ref.watch(desktopLocalClientProvider);
  return TerminalViewModel(
    apiClient: apiClient,
    eventClient: eventClient,
    desktopLocalClient: desktopLocalClient,
    config: config,
  );
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
}
