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
  reset,
  output,
}

@immutable
class TerminalUiEvent {
  const TerminalUiEvent.reset()
      : type = TerminalUiEventType.reset,
        text = '';

  const TerminalUiEvent.output(this.text) : type = TerminalUiEventType.output;

  final TerminalUiEventType type;
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
  final StringBuffer _pendingInput = StringBuffer();

  WebSocketChannel? _channel;
  _TerminalTransport? _transport;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _inputTimer;
  Timer? _resizeTimer;
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
          _events.add(const TerminalUiEvent.reset());
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
      final terminals = [created, ...state.terminals];
      state = state.copyWith(
        terminals: terminals,
        activeTerminalId: created.id,
        clearError: true,
      );
      await attachTerminal(created.id, resetViewport: true);
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

    try {
      await _apiClient.closeTerminal(
        accessToken: _config.accessToken,
        terminalId: terminalId,
      );
      final remaining = state.terminals
          .where((item) => item.id != terminalId)
          .toList(growable: false);
      final nextActiveId = remaining.isEmpty ? null : remaining.first.id;
      state = state.copyWith(
        terminals: remaining,
        activeTerminalId: nextActiveId,
        clearActiveTerminalId: nextActiveId == null,
        clearError: true,
      );

      await _detachChannel();
      _events.add(const TerminalUiEvent.reset());

      if (nextActiveId != null) {
        await attachTerminal(nextActiveId);
      } else if (_shouldCreateDefaultTerminal) {
        await createTerminal(autoCreated: true);
      }
    } catch (error) {
      state = state.copyWith(
        errorMessage: AppLocalizations.current.terminalCloseFailed('$error'),
      );
    }
  }

  Future<void> attachTerminal(
    String terminalId, {
    bool resetViewport = true,
  }) async {
    final alreadyAttached =
        state.activeTerminalId == terminalId && _channel != null && !state.connecting;
    if (alreadyAttached) {
      return;
    }

    await _detachChannel();
    if (resetViewport) {
      _events.add(const TerminalUiEvent.reset());
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

  void queueInput(String data) {
    if (data.isEmpty) {
      return;
    }

    _pendingInput.write(data);
    if (_shouldFlushInputImmediately(data)) {
      _flushPendingInput();
      return;
    }

    _inputTimer?.cancel();
    _inputTimer = Timer(_terminalInputDebounce, _flushPendingInput);
  }

  void queueResize({
    required int cols,
    required int rows,
  }) {
    if (cols <= 0 || rows <= 0) {
      return;
    }

    final activeTerminalId = state.activeTerminalId;
    if (activeTerminalId == null) {
      return;
    }

    _pendingResize = _QueuedResize(
      terminalId: activeTerminalId,
      cols: cols,
      rows: rows,
    );

    _resizeTimer?.cancel();
    _resizeTimer = Timer(_terminalResizeDebounce, _flushPendingResize);
  }

  Future<void> _detachChannel() async {
    _flushPendingInput();
    _flushPendingResize();
    _inputTimer?.cancel();
    _inputTimer = null;
    _resizeTimer?.cancel();
    _resizeTimer = null;

    final channel = _channel;
    final subscription = _channelSubscription;
    _channel = null;
    _transport = null;
    _channelSubscription = null;
    await subscription?.cancel();
    await channel?.sink.close();
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
      case 'terminal.output':
        if (!_isEventForActiveTerminal(body)) {
          return;
        }
        final data = body['data_base64'] as String?;
        if (data == null) {
          return;
        }
        final bytes = base64Decode(data);
        _events.add(
          TerminalUiEvent.output(
            const Utf8Decoder(allowMalformed: true).convert(bytes),
          ),
        );
        break;
      case 'terminal.closed':
        if (!_isEventForActiveTerminal(body)) {
          return;
        }
        _updateActiveTerminalState('closed');
        _events.add(const TerminalUiEvent.output('\r\n[terminal closed]\r\n'));
        break;
      case 'terminal.error':
        if (!_isEventForActiveTerminal(body)) {
          return;
        }
        final message = body['error_message'] as String? ?? 'unknown';
        _updateActiveTerminalState('error');
        state = state.copyWith(
          errorMessage: AppLocalizations.current.terminalStreamError(message),
        );
        _events.add(TerminalUiEvent.output('\r\n[terminal error] $message\r\n'));
        break;
      default:
        break;
    }
  }

  bool _isEventForActiveTerminal(Map<String, dynamic> body) {
    final eventTerminalId = body['terminal_id'] as String?;
    final activeTerminalId = state.activeTerminalId;
    if (eventTerminalId == null || activeTerminalId == null) {
      return true;
    }
    return eventTerminalId == activeTerminalId;
  }

  void _handleTerminalReady(Map<String, dynamic> body) {
    final terminalId =
        body['terminal_id'] as String? ?? state.activeTerminalId ?? '';
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

  void _updateActiveTerminalState(String nextState) {
    final activeTerminalId = state.activeTerminalId;
    if (activeTerminalId == null) {
      return;
    }
    _updateTerminalSummary(
      activeTerminalId,
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

    final data = _pendingInput.toString();
    if (data.isEmpty) {
      return;
    }
    _pendingInput.clear();

    final channel = _channel;
    if (channel == null) {
      return;
    }

    final activeTerminalId = state.activeTerminalId;
    if (activeTerminalId == null) {
      return;
    }

    final payload = base64Encode(utf8.encode(data));
    if (_transport == _TerminalTransport.desktopLocal) {
      _desktopLocalClient?.sendTerminalInput(
        channel: channel,
        terminalId: activeTerminalId,
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

enum _TerminalTransport {
  backend,
  desktopLocal,
}
