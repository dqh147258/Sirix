import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum AppLogSource {
  flutterMobile('flutter_mobile'),
  flutterDesktop('flutter_desktop');

  const AppLogSource(this.apiValue);

  final String apiValue;
}

class AppLogger {
  AppLogger._();

  static const _runtimeSettingsPath = '/api/v1/runtime/settings';
  static const _runtimeLogsPath = '/api/v1/runtime/logs';
  static const _maxBufferedEntries = 5000;
  static const _maxBatchSize = 64;

  static AppLogSource? _source;
  static String? _baseUrl;
  static bool _loggingEnabled = true;
  static final List<_PendingRuntimeLogEntry> _pendingEntries = [];
  static bool _refreshingSettings = false;
  static bool _flushing = false;
  static Timer? _settingsRefreshTimer;

  static Future<void> bootstrap({
    required AppLogSource source,
    required String baseUrl,
  }) async {
    _source = source;
    _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    _settingsRefreshTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(refreshSettings());
    });
    await refreshSettings();
  }

  static void configure({
    required AppLogSource source,
    required String baseUrl,
  }) {
    unawaited(bootstrap(source: source, baseUrl: baseUrl));
  }

  static Future<void> refreshSettings() async {
    final baseUrl = _baseUrl;
    if (_refreshingSettings || baseUrl == null || baseUrl.isEmpty) {
      return;
    }

    _refreshingSettings = true;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$baseUrl$_runtimeSettingsPath'));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          setEnabled(decoded['logging_enabled'] as bool? ?? true);
        }
      }
    } catch (_) {
      setEnabled(true);
    } finally {
      client.close(force: true);
      _refreshingSettings = false;
    }

    unawaited(_flushPending());
  }

  static void setEnabled(bool enabled) {
    _loggingEnabled = enabled;
    if (!enabled) {
      _pendingEntries.clear();
      return;
    }
    unawaited(_flushPending());
  }

  static void trace(String message, {Map<String, Object?>? context}) {
    _log('TRACE', message, context: context);
  }

  static void info(String message, {Map<String, Object?>? context}) {
    _log('INFO', message, context: context);
  }

  static void warn(String message, {Map<String, Object?>? context}) {
    _log('WARN', message, context: context);
  }

  static void error(String message, {Map<String, Object?>? context}) {
    _log('ERROR', message, context: context);
  }

  static void _log(
    String level,
    String message, {
    Map<String, Object?>? context,
  }) {
    if (!_loggingEnabled) {
      return;
    }

    final entry = _PendingRuntimeLogEntry(
      timestamp: DateTime.now().toUtc(),
      level: level,
      message: message,
      context: context,
    );

    _pendingEntries.add(entry);
    if (_pendingEntries.length > _maxBufferedEntries) {
      _pendingEntries.removeRange(0, _pendingEntries.length - _maxBufferedEntries);
    }

    final source = _source;
    final sourceLabel = source == null ? 'flutter' : source.apiValue;
    debugPrint('[$sourceLabel][$level] $message');

    unawaited(_flushPending());
  }

  static Future<void> _flushPending() async {
    final source = _source;
    final baseUrl = _baseUrl;
    if (_flushing ||
        !_loggingEnabled ||
        source == null ||
        baseUrl == null ||
        baseUrl.isEmpty ||
        _pendingEntries.isEmpty) {
      return;
    }

    _flushing = true;
    final client = HttpClient();
    try {
      while (_pendingEntries.isNotEmpty) {
        final batchSize = _pendingEntries.length < _maxBatchSize
            ? _pendingEntries.length
            : _maxBatchSize;
        final batch = _pendingEntries.take(batchSize).toList(growable: false);
        final request = await client.postUrl(Uri.parse('$baseUrl$_runtimeLogsPath'));
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'source': source.apiValue,
            'entries': batch.map((entry) => entry.toJson()).toList(growable: false),
          }),
        );

        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          break;
        }

        _pendingEntries.removeRange(0, batch.length);
      }
    } catch (_) {
      // Keep the buffered logs for the next flush attempt.
    } finally {
      client.close(force: true);
      _flushing = false;
    }
  }
}

class _PendingRuntimeLogEntry {
  const _PendingRuntimeLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    required this.context,
  });

  final DateTime timestamp;
  final String level;
  final String message;
  final Map<String, Object?>? context;

  Map<String, Object?> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'level': level,
      'message': message,
      if (context != null && context!.isNotEmpty) 'context': context,
    };
  }
}
