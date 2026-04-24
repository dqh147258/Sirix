part of 'terminal_view_model.dart';

abstract class _TerminalViewModelStateBase extends BaseViewModel<TerminalState> {
  _TerminalViewModelStateBase({
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
        _sessionTerminalChannelController.messages.listen(_forwardSessionChannelEvent);
  }

  final BackendApiClient _apiClient;
  final BackendEventClient? _eventClient;
  final DesktopLocalClient? _desktopLocalClient;
  final SessionTerminalChannelController _sessionTerminalChannelController;
  final int _vmDebugId = _nextTerminalViewModelDebugId++;
  TerminalPageConfig _config;
  final Map<String, Terminal> _terminalCache = <String, Terminal>{};
  final Map<String, TerminalStreamState> _terminalStreams = <String, TerminalStreamState>{};
  final Map<String, TerminalAuthorityCache> _terminalAuthorities =
      <String, TerminalAuthorityCache>{};
  final Map<String, int> _viewerPresenceEpochByTerminal = <String, int>{};
  final Set<String> _snapshotApplyingTerminals = <String>{};
  final Set<String> _autoCreatedTerminalIds = <String>{};
  final Map<String, String> _lastReadySignaturesByTerminal = <String, String>{};

  WebSocketChannel? _channel;
  _TerminalTransport? _transport;
  StreamSubscription<dynamic>? _channelSubscription;
  StreamSubscription<Map<String, dynamic>>? _sessionChannelSubscription;
  Future<WebSocketChannel>? _desktopLocalChannelConnectFuture;
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
  _TerminalViewportSize? _lastObservedViewportSize;
  bool _resizeTrailingWindowActive = false;
  Completer<List<TerminalSessionSummary>>? _pendingSessionTerminalListCompleter;
  Completer<List<TerminalSessionSummary>>? _pendingDesktopLocalTerminalListCompleter;
  bool _hasLoaded = false;
  bool _loadingInFlight = false;
  bool _creatingInFlight = false;
  bool _disposed = false;
  String? _attachingTerminalId;

  void updateConfig(TerminalPageConfig config) {
    _config = config;
  }

  void _handleSessionChannelEvent(Map<String, dynamic> payload);
  void _disposeInternal();

  TerminalState get _currentStateSnapshot => state;

  void _replaceTerminalState(TerminalState nextState) {
    state = nextState;
  }

  void _forwardSessionChannelEvent(Map<String, dynamic> payload) {
    _handleSessionChannelEvent(payload);
  }

  @override
  void dispose() {
    _disposeInternal();
    super.dispose();
  }
}
