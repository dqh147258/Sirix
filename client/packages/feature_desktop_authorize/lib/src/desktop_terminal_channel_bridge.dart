import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

const int _maxPendingTerminalBridgeMessages = 96;

class DesktopTerminalChannelBridge {
  DesktopTerminalChannelBridge({
    required DesktopLocalClient localClient,
    required SessionTerminalChannelController terminalChannelController,
  })  : _localClient = localClient,
        _terminalChannelController = terminalChannelController {
    _remoteSubscription = _terminalChannelController.messages.listen(_handleRemoteMessage);
  }

  final DesktopLocalClient _localClient;
  final SessionTerminalChannelController _terminalChannelController;
  final List<String> _pendingMessages = <String>[];
  final Map<String, String> _attachedTerminalMessages = <String, String>{};

  WebSocketChannel? _localChannel;
  StreamSubscription<dynamic>? _localSubscription;
  StreamSubscription<Map<String, dynamic>>? _remoteSubscription;
  Timer? _reconnectTimer;
  String? _sessionId;
  bool _connecting = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;

  Future<void> bindSession(String sessionId) async {
    if (_disposed) {
      return;
    }

    if (_sessionId != sessionId) {
      _sessionId = sessionId;
      _pendingMessages.clear();
    }
    await _ensureLocalChannel();
  }

  Future<void> unbindSession([String? sessionId]) async {
    if (sessionId != null && _sessionId != null && _sessionId != sessionId) {
      return;
    }

    _sessionId = null;
    _detachTrackedTerminals();
    _pendingMessages.clear();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeLocalChannel();
  }

  Future<void> dispose() async {
    _disposed = true;
    await unbindSession();
    await _remoteSubscription?.cancel();
    _remoteSubscription = null;
  }

  void _handleRemoteMessage(Map<String, dynamic> payload) {
    if (_disposed || _sessionId == null) {
      return;
    }

    final type = payload['type'] as String?;
    if (!_isInboundTerminalCommand(type)) {
      return;
    }

    _trackAttachmentState(payload, type);

    final encoded = jsonEncode(payload);
    final channel = _localChannel;
    if (channel == null) {
      _enqueuePendingMessage(encoded);
      unawaited(_ensureLocalChannel());
      return;
    }

    channel.sink.add(encoded);
  }

  bool _isInboundTerminalCommand(String? type) {
    switch (type) {
      case 'terminal.list':
      case 'terminal.attach':
      case 'terminal.bootstrap.request':
      case 'terminal.history.range.request':
      case 'terminal.close':
      case 'terminal.detach':
      case 'terminal.input':
      case 'terminal.resize':
      case 'ping':
        return true;
      default:
        return false;
    }
  }

  void _handleLocalMessage(dynamic raw) {
    if (_disposed || _sessionId == null) {
      return;
    }

    final decoded = DesktopLocalClient.decodeEvent(raw);
    if (decoded == null) {
      return;
    }

    final type = decoded['type'] as String?;
    if (type == null || !type.startsWith('terminal.')) {
      return;
    }

    unawaited(_terminalChannelController.sendJson(decoded));
  }

  Future<void> _ensureLocalChannel() async {
    if (_disposed || _sessionId == null || _localChannel != null || _connecting) {
      return;
    }

    _connecting = true;
    try {
      final channel = await _localClient.connect();
      _localChannel = channel;
      _reconnectAttempt = 0;
      _localSubscription = channel.stream.listen(
        _handleLocalMessage,
        onError: (Object error, StackTrace stackTrace) {
          AppLogger.warn('desktop terminal bridge local ws error error=$error');
          unawaited(_handleLocalDisconnect());
        },
        onDone: () {
          AppLogger.warn('desktop terminal bridge local ws disconnected');
          unawaited(_handleLocalDisconnect());
        },
      );
      _flushPendingMessages();
      _replayTrackedAttachments();
    } catch (error) {
      AppLogger.warn('desktop terminal bridge local ws connect failed error=$error');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _handleLocalDisconnect() async {
    await _closeLocalChannel();
    _scheduleReconnect();
  }

  Future<void> _closeLocalChannel() async {
    final subscription = _localSubscription;
    final channel = _localChannel;
    _localSubscription = null;
    _localChannel = null;
    await subscription?.cancel();
    await channel?.sink.close();
  }

  void _enqueuePendingMessage(String encoded) {
    if (_pendingMessages.length >= _maxPendingTerminalBridgeMessages) {
      _pendingMessages.removeAt(0);
    }
    _pendingMessages.add(encoded);
  }

  void _flushPendingMessages() {
    final channel = _localChannel;
    if (channel == null || _pendingMessages.isEmpty) {
      return;
    }

    for (final message in _pendingMessages) {
      channel.sink.add(message);
    }
    _pendingMessages.clear();
  }

  void _trackAttachmentState(Map<String, dynamic> payload, String? type) {
    if (type == 'terminal.attach') {
      final body = payload['payload'] as Map<String, dynamic>?;
      final terminalId = body?['terminal_id'] as String?;
      if (terminalId != null && terminalId.isNotEmpty) {
        _attachedTerminalMessages[terminalId] = jsonEncode(payload);
      }
      return;
    }
    if (type == 'terminal.close' || type == 'terminal.detach') {
      final payloadBody = payload['payload'] as Map<String, dynamic>?;
      final terminalId =
          payload['terminal_id'] as String? ?? payloadBody?['terminal_id'] as String?;
      if (terminalId != null && terminalId.isNotEmpty) {
        _attachedTerminalMessages.remove(terminalId);
      }
    }
  }

  void _replayTrackedAttachments() {
    final channel = _localChannel;
    if (channel == null || _attachedTerminalMessages.isEmpty) {
      return;
    }

    for (final entry in _attachedTerminalMessages.entries) {
      channel.sink.add(entry.value);
      _localClient.sendTerminalBootstrapRequest(
        channel: channel,
        terminalId: entry.key,
      );
    }
  }

  void _detachTrackedTerminals() {
    final channel = _localChannel;
    if (channel != null) {
      for (final terminalId in _attachedTerminalMessages.keys) {
        _localClient.sendTerminalDetach(
          channel: channel,
          terminalId: terminalId,
          clientKind: 'mobile_app',
        );
      }
    }
    _attachedTerminalMessages.clear();
  }

  void _scheduleReconnect() {
    if (_disposed || _sessionId == null || _reconnectTimer != null) {
      return;
    }

    _reconnectAttempt += 1;
    final delay = Duration(
      milliseconds: (300 * (1 << (_reconnectAttempt - 1))).clamp(300, 4000).toInt(),
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_ensureLocalChannel());
    });
  }
}
