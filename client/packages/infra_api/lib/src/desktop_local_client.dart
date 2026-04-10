import 'dart:async';
import 'dart:convert';

import 'package:app_core/app_core.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ai_models.dart';
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
  int? _resolvedPort;

  Future<WebSocketChannel> connect() async {
    final errors = <String>[];

    for (final port in _candidatePorts()) {
      final uri = Uri.parse('ws://$host:$port$path');
      try {
        AppLogger.trace('try desktop local ws: $uri');
        final channel = WebSocketChannel.connect(uri);
        await channel.ready.timeout(const Duration(milliseconds: 900));
        _resolvedPort = port;
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

  Future<AuthSession?> getAuthSession() async {
    final response = await _request('GET', '/auth/session');
    if (response.statusCode == 204) {
      return null;
    }
    return AuthSession.fromJson(_decodeMap(response));
  }

  Future<AuthSession> login({
    required String username,
    required String password,
  }) async {
    final response = await _request(
      'POST',
      '/auth/session',
      body: {
        'username': username,
        'password': password,
      },
    );
    return AuthSession.fromJson(_decodeMap(response));
  }

  Future<AuthSession> register({
    required String username,
    required String password,
  }) async {
    final response = await _request(
      'POST',
      '/auth/register',
      body: {
        'username': username,
        'password': password,
      },
    );
    return AuthSession.fromJson(_decodeMap(response));
  }

  Future<void> logout() async {
    final response = await _request('DELETE', '/auth/session');
    if (response.statusCode != 204) {
      _decodeMap(response);
    }
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

  Future<SirixAiConfig> getAiConfig() async {
    final response = await _request('GET', '/ai/config');
    return SirixAiConfig.fromJson(_decodeMap(response));
  }

  Future<EffectiveSirixAiConfig> getEffectiveAiConfig({String? cwd}) async {
    final suffix = (cwd == null || cwd.isEmpty)
        ? ''
        : '?cwd=${Uri.encodeQueryComponent(cwd)}';
    final response = await _request('GET', '/ai/config/effective$suffix');
    return EffectiveSirixAiConfig.fromJson(_decodeMap(response));
  }

  Future<SirixAiConfig> saveAiConfig(SirixAiConfig config) async {
    final response = await _request(
      'PATCH',
      '/ai/config',
      body: config.toJson(),
    );
    return SirixAiConfig.fromJson(_decodeMap(response));
  }

  Future<Map<String, dynamic>> checkAiApproval({
    required String sessionId,
    required String capabilityKey,
  }) async {
    final response = await _request(
      'POST',
      '/ai/sessions/approvals/check',
      body: {
        'session_id': sessionId,
        'capability_key': capabilityKey,
      },
    );
    return _decodeMap(response);
  }

  Future<void> resolveAiApproval({
    required String sessionId,
    required String capabilityKey,
    required String decision,
    required String scope,
  }) async {
    await _request(
      'POST',
      '/ai/sessions/approvals/resolve',
      body: {
        'session_id': sessionId,
        'capability_key': capabilityKey,
        'decision': decision,
        'scope': scope,
      },
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

  void sendTerminalClose({
    required WebSocketChannel channel,
    required String terminalId,
  }) {
    channel.sink.add(
      jsonEncode({
        'type': 'terminal.close',
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

  Iterable<int> _candidatePorts() sync* {
    final resolvedPort = _resolvedPort;
    if (resolvedPort != null && resolvedPort >= portStart && resolvedPort <= portEnd) {
      yield resolvedPort;
    }
    for (var port = portStart; port <= portEnd; port += 1) {
      if (port == resolvedPort) {
        continue;
      }
      yield port;
    }
  }

  Future<http.Response> _request(
    String method,
    String requestPath, {
    Map<String, dynamic>? body,
  }) async {
    final errors = <String>[];

    for (final port in _candidatePorts()) {
      final uri = Uri.parse('http://$host:$port$requestPath');
      try {
        final response = switch (method) {
          'GET' => await http.get(uri),
          'POST' => await http.post(
              uri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(body ?? const <String, dynamic>{}),
            ),
          'PATCH' => await http.patch(
              uri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(body ?? const <String, dynamic>{}),
            ),
          'DELETE' => await http.delete(uri),
          _ => throw UnsupportedError('unsupported method $method'),
        };
        _resolvedPort = port;
        return response;
      } catch (error) {
        errors.add('$port:$error');
      }
    }

    throw StateError(
      '无法连接 desktop-server 本地HTTP，已尝试端口 $portStart-$portEnd: ${errors.join('; ')}',
    );
  }

  Map<String, dynamic> _decodeMap(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}: ${response.body}');
    }

    if (response.body.isEmpty) {
      return const <String, dynamic>{};
    }

    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }
}
