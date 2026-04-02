import 'dart:convert';
import 'dart:io';

import 'package:infra_api/infra_api.dart';
import 'package:path_provider/path_provider.dart';

class AuthSessionStore {
  Future<AuthSession?> load(String clientType) async {
    final file = await _sessionFile(clientType);
    if (!await file.exists()) {
      return null;
    }

    final raw = await file.readAsString();
    if (raw.isEmpty) {
      return null;
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      await clear(clientType);
      return null;
    }

    return AuthSession.fromJson(decoded);
  }

  Future<void> save(String clientType, AuthSession session) async {
    final file = await _sessionFile(clientType);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(session.toJson()), flush: true);
  }

  Future<void> clear(String clientType) async {
    final file = await _sessionFile(clientType);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _sessionFile(String clientType) async {
    final baseDirectory = await _baseDirectory();
    return File('${baseDirectory.path}/sirix/auth_session_$clientType.json');
  }

  Future<Directory> _baseDirectory() async {
    try {
      return await getApplicationSupportDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }
}
