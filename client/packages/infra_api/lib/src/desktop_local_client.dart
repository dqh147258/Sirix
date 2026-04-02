import 'dart:async';
import 'dart:convert';

import 'package:app_core/app_core.dart';
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
        AppLogger.trace('try desktop local ws: $uri');
        final channel = WebSocketChannel.connect(uri);
        await channel.ready.timeout(const Duration(milliseconds: 900));
        AppLogger.info('desktop local ws connected: $uri');
        return channel;
      } catch (error) {
        AppLogger.warn('desktop local ws connect failed: $uri error=$error');
        errors.add('$port:$error');
      }
    }

    throw StateError(
      '无法连接 desktop-server 本地WS，已尝试端口 $portStart-$portEnd: ${errors.join('; ')}',
    );
  }

  Future<List<TerminalSessionSummary>> listTerminalSessions() async {
    final channel = await connect();
    try {
      channel.sink.add(
        jsonEncode({
          'type': 'terminal.list',
        }),
      );

      await for (final raw in channel.stream.timeout(const Duration(milliseconds: 1200))) {
        final decoded = decodeEvent(raw);
        if (decoded == null) {
          continue;
        }

        final type = decoded['type'] as String?;
        if (type != 'terminal.list') {
          continue;
        }

        final payload = decoded['payload'] as Map<String, dynamic>?;
        final terminals = payload?['terminals'] as List<dynamic>? ?? const [];
        return terminals
            .whereType<Map<String, dynamic>>()
            .map(_terminalFromLocalEvent)
            .toList(growable: false);
      }
    } finally {
      await channel.sink.close();
    }

    return const [];
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

  void sendTerminalAttach({
    required WebSocketChannel channel,
    required String terminalId,
  }) {
    channel.sink.add(
      jsonEncode({
        'type': 'terminal.attach',
        'terminal_id': terminalId,
      }),
    );
  }

  void sendTerminalInput({
    required WebSocketChannel channel,
    required String terminalId,
    required String dataBase64,
  }) {
    channel.sink.add(
      jsonEncode({
        'type': 'terminal.input',
        'terminal_id': terminalId,
        'data_base64': dataBase64,
      }),
    );
  }

  void sendTerminalResize({
    required WebSocketChannel channel,
    required String terminalId,
    required int cols,
    required int rows,
  }) {
    channel.sink.add(
      jsonEncode({
        'type': 'terminal.resize',
        'terminal_id': terminalId,
        'cols': cols,
        'rows': rows,
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

  static TerminalSessionSummary _terminalFromLocalEvent(Map<String, dynamic> json) {
    return TerminalSessionSummary(
      id: json['terminal_id'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? '',
      title: json['title'] as String? ?? 'Terminal',
      shell: json['shell'] as String? ?? 'default',
      cwd: json['cwd'] as String? ?? '~',
      state: json['state'] as String? ?? 'active',
      cols: (json['cols'] as num?)?.toInt() ?? 120,
      rows: (json['rows'] as num?)?.toInt() ?? 32,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
      closedAt: json['closed_at'] == null
          ? null
          : DateTime.tryParse(json['closed_at'] as String? ?? ''),
    );
  }
}
