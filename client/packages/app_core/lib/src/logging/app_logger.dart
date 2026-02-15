import 'package:flutter/foundation.dart';

class AppLogger {
  AppLogger._();

  static void trace(String message) {
    debugPrint('[TRACE] $message');
  }

  static void info(String message) {
    debugPrint('[INFO] $message');
  }

  static void warn(String message) {
    debugPrint('[WARN] $message');
  }

  static void error(String message) {
    debugPrint('[ERROR] $message');
  }
}
