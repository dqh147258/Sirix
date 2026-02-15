import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';

enum QualityProfile {
  p480,
  p720,
  p1080,
}

@immutable
class RemoteStreamState {
  const RemoteStreamState({
    this.connected = false,
    this.autoQuality = true,
    this.qualityProfile = QualityProfile.p720,
    this.lastSignalType,
    this.lastUpdated,
  });

  final bool connected;
  final bool autoQuality;
  final QualityProfile qualityProfile;
  final String? lastSignalType;
  final DateTime? lastUpdated;

  RemoteStreamState copyWith({
    bool? connected,
    bool? autoQuality,
    QualityProfile? qualityProfile,
    String? lastSignalType,
    DateTime? lastUpdated,
  }) {
    return RemoteStreamState(
      connected: connected ?? this.connected,
      autoQuality: autoQuality ?? this.autoQuality,
      qualityProfile: qualityProfile ?? this.qualityProfile,
      lastSignalType: lastSignalType ?? this.lastSignalType,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}

class RemoteStreamController extends BaseViewModel<RemoteStreamState> {
  RemoteStreamController() : super(const RemoteStreamState());

  Future<void> connect() async {
    AppLogger.info('connect remote stream');
    state = state.copyWith(connected: true, lastUpdated: DateTime.now());
  }

  Future<void> disconnect() async {
    AppLogger.info('disconnect remote stream');
    state = state.copyWith(connected: false, lastUpdated: DateTime.now());
  }

  Future<void> setAutoQuality(bool value) async {
    state = state.copyWith(autoQuality: value, lastUpdated: DateTime.now());
  }

  Future<void> setQualityProfile(QualityProfile profile) async {
    state = state.copyWith(
      autoQuality: false,
      qualityProfile: profile,
      lastUpdated: DateTime.now(),
    );
  }

  Future<String> createOffer() async {
    final now = DateTime.now();
    state = state.copyWith(lastSignalType: 'offer.local.created', lastUpdated: now);
    return 'v=0\no=mobile ${now.microsecondsSinceEpoch} 2 IN IP4 127.0.0.1\ns=freeloom\nt=0 0\na=group:BUNDLE 0\na=msid-semantic: WMS\n';
  }

  Future<String> createAnswerForOffer(String remoteOffer) async {
    final now = DateTime.now();
    state = state.copyWith(lastSignalType: 'answer.local.created', lastUpdated: now);
    return 'v=0\no=mobile-answer ${now.microsecondsSinceEpoch} 2 IN IP4 127.0.0.1\ns=freeloom\nt=0 0\na=group:BUNDLE 0\na=setup:active\n';
  }

  Future<void> applyRemoteAnswer(String sdp) async {
    AppLogger.info('apply remote answer length=${sdp.length}');
    state = state.copyWith(lastSignalType: 'answer.remote.applied', lastUpdated: DateTime.now());
  }

  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {
    AppLogger.trace('apply remote candidate: $candidate');
    state = state.copyWith(lastSignalType: 'candidate.remote.applied', lastUpdated: DateTime.now());
  }
}

final remoteStreamControllerProvider =
    StateNotifierProvider<RemoteStreamController, RemoteStreamState>((ref) {
  return RemoteStreamController();
});
