import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalThemes;

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

import 'terminal_state.dart';

part 'terminal_view_model_state_base.dart';
part 'terminal_view_model_transport.dart';
part 'terminal_view_model_transport_history.dart';
part 'terminal_view_model_runtime.dart';
part 'terminal_view_model_runtime_snapshot.dart';
part 'terminal_view_model_events_a.dart';
part 'terminal_view_model_events_approval.dart';
part 'terminal_view_model_events_b.dart';
part 'terminal_view_model_load.dart';
part 'terminal_view_model_models.dart';
part 'terminal_view_model_visible_window.dart';

const Duration _terminalInputDebounce = Duration(milliseconds: 12);
const Duration _terminalResizeTrailingDebounce = Duration(milliseconds: 32);
const Duration _terminalMobileResizeDebounce = Duration(milliseconds: 96);
const Duration _terminalSessionAttachRetryDelay = Duration(milliseconds: 180);
const Duration _desktopLocalAttachReconcileDelay = Duration(milliseconds: 220);
const Duration _terminalSessionListRetryDelay = Duration(milliseconds: 320);
const Duration _terminalSessionListTimeout = Duration(milliseconds: 2400);
const int _terminalImmediateInputThreshold = 128;
const int _terminalSessionAttachRetryCount = 6;
const int _terminalSessionListRetryCount = 3;
const int _terminalAuthorityCacheMaxLines = 8000;
const int _terminalHistoryPrefetchChunkLines = 2000;
const int _terminalVisibleSnapshotMaxTrailingBlankRows = 15;
const String _terminalStreamTraceTag = '[TERMINAL_STREAM_TRACE]';
const String _terminalSyncModeV2 = authorityTerminalSyncMode;
const String _terminalOscTraceTag = '[TERMINAL_OSC_TRACE]';
const Duration _terminalAuthorityRefreshInterval = Duration(milliseconds: 80);

@immutable
class TerminalPageConfig {
  const TerminalPageConfig({
    required this.accessToken,
    required this.deviceId,
    required this.sessionId,
  });

  // UI presentation flags are intentionally excluded so every entry point
  // shares the same terminal workspace for a given authenticated session/device.
  final String accessToken;
  final String? deviceId;
  final String? sessionId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TerminalPageConfig &&
            runtimeType == other.runtimeType &&
            accessToken == other.accessToken &&
            deviceId == other.deviceId &&
            sessionId == other.sessionId;
  }

  @override
  int get hashCode => Object.hash(accessToken, deviceId, sessionId);
}

class TerminalViewModel extends _TerminalViewModelLoadBase {
  TerminalViewModel({
    required super.apiClient,
    required super.eventClient,
    required super.desktopLocalClient,
    required super.sessionTerminalChannelController,
    required super.config,
  });
}

final terminalViewModelProvider =
    StateNotifierProvider.family<TerminalViewModel, TerminalState, TerminalPageConfig>((
  ref,
  config,
) {
  final apiClient = ref.watch(backendApiClientProvider);
  final eventClient = ref.watch(backendEventClientProvider);
  final desktopLocalClient = ref.watch(desktopLocalClientProvider);
  final sessionTerminalChannelController = ref.watch(
    sessionTerminalChannelControllerProvider.notifier,
  );
  final viewModel = TerminalViewModel(
    apiClient: apiClient,
    eventClient: eventClient,
    desktopLocalClient: desktopLocalClient,
    sessionTerminalChannelController: sessionTerminalChannelController,
    config: config,
  );
  ref.listen<SessionTerminalChannelState>(
    sessionTerminalChannelControllerProvider,
    (previous, next) {
      viewModel.onSessionTerminalChannelStateChanged(previous, next);
    },
  );
  return viewModel;
});
