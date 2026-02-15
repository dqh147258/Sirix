import 'package:flutter/foundation.dart';

import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

enum ViewOrientationMode {
  portrait,
  landscape,
}

@immutable
class RemoteViewState {
  const RemoteViewState({
    this.sessionId,
    this.deviceId,
    this.sessionState,
    this.loading = false,
    this.backgroundPauseDeadline,
    this.snapshotRefreshSeconds = 5,
    this.orientationMode = ViewOrientationMode.portrait,
    this.autoQuality = true,
    this.qualityProfile = QualityProfile.p720,
    this.snapshots = const [],
    this.selectedScreenId,
    this.lastEventType,
    this.errorMessage,
  });

  static const _unset = Object();

  final String? sessionId;
  final String? deviceId;
  final String? sessionState;
  final bool loading;
  final DateTime? backgroundPauseDeadline;
  final int snapshotRefreshSeconds;
  final ViewOrientationMode orientationMode;
  final bool autoQuality;
  final QualityProfile qualityProfile;
  final List<ScreenSnapshot> snapshots;
  final String? selectedScreenId;
  final String? lastEventType;
  final String? errorMessage;

  RemoteViewState copyWith({
    Object? sessionId = _unset,
    Object? deviceId = _unset,
    Object? sessionState = _unset,
    bool? loading,
    Object? backgroundPauseDeadline = _unset,
    int? snapshotRefreshSeconds,
    ViewOrientationMode? orientationMode,
    bool? autoQuality,
    QualityProfile? qualityProfile,
    List<ScreenSnapshot>? snapshots,
    Object? selectedScreenId = _unset,
    Object? lastEventType = _unset,
    String? errorMessage,
    bool clearError = false,
  }) {
    return RemoteViewState(
      sessionId: identical(sessionId, _unset) ? this.sessionId : sessionId as String?,
      deviceId: identical(deviceId, _unset) ? this.deviceId : deviceId as String?,
      sessionState: identical(sessionState, _unset) ? this.sessionState : sessionState as String?,
      loading: loading ?? this.loading,
      backgroundPauseDeadline: identical(backgroundPauseDeadline, _unset)
          ? this.backgroundPauseDeadline
          : backgroundPauseDeadline as DateTime?,
      snapshotRefreshSeconds: snapshotRefreshSeconds ?? this.snapshotRefreshSeconds,
      orientationMode: orientationMode ?? this.orientationMode,
      autoQuality: autoQuality ?? this.autoQuality,
      qualityProfile: qualityProfile ?? this.qualityProfile,
      snapshots: snapshots ?? this.snapshots,
      selectedScreenId: identical(selectedScreenId, _unset)
          ? this.selectedScreenId
          : selectedScreenId as String?,
      lastEventType: identical(lastEventType, _unset) ? this.lastEventType : lastEventType as String?,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
