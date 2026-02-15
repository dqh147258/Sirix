import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class BackendEventClient {
  BackendEventClient({required String baseUrl}) : _baseUrl = baseUrl;

  final String _baseUrl;

  WebSocketChannel connectMobileEvents({required String accessToken}) {
    final wsBase = _baseUrl.startsWith('https://')
        ? _baseUrl.replaceFirst('https://', 'wss://')
        : _baseUrl.replaceFirst('http://', 'ws://');

    final uri = Uri.parse('$wsBase/api/v1/mobile/events/ws');
    return WebSocketChannel.connect(
      uri,
      protocols: const [],
      headers: {
        'Authorization': 'Bearer $accessToken',
      },
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
