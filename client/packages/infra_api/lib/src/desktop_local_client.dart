import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

class DesktopLocalClient {
  DesktopLocalClient({
    required this.host,
    required this.portStart,
    required this.portEnd,
    this.path = '/ws',
  });

  final String host;
  final int portStart;
  final int portEnd;
  final String path;

  Future<WebSocketChannel> connect() async {
    final errors = <String>[];

    for (var port = portStart; port <= portEnd; port += 1) {
      final uri = Uri.parse('ws://$host:$port$path');
      try {
        final channel = WebSocketChannel.connect(uri);
        await channel.ready.timeout(const Duration(milliseconds: 900));
        return channel;
      } catch (error) {
        errors.add('$port:$error');
      }
    }

    throw StateError(
      '无法连接 desktop-server 本地WS，已尝试端口 $portStart-$portEnd: ${errors.join('; ')}',
    );
  }

  void sendSetAutoApprove({
    required WebSocketChannel channel,
    required bool autoApprove,
  }) {
    channel.sink.add(
      jsonEncode({
        'type': 'settings.set_auto_approve',
        'auto_approve_screen_share': autoApprove,
      }),
    );
  }

  void sendAuthorizeResponse({
    required WebSocketChannel channel,
    required String sessionId,
    required bool approve,
  }) {
    channel.sink.add(
      jsonEncode({
        'type': 'authorize.response',
        'session_id': sessionId,
        'decision': approve ? 'approve' : 'reject',
      }),
    );
  }

  void sendWebrtcSignal({
    required WebSocketChannel channel,
    required String sessionId,
    required WebrtcSignalType signalType,
    String? sdp,
    Map<String, dynamic>? candidate,
  }) {
    channel.sink.add(
      jsonEncode({
        'type': 'webrtc.signal',
        'session_id': sessionId,
        'signal_type': signalType.apiValue,
        'sdp': sdp,
        'candidate': candidate,
      }),
    );
  }

  static Map<String, dynamic>? decodeEvent(dynamic raw) {
    if (raw is String) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    }
    return null;
  }
}
