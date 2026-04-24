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
int _nextTerminalViewModelDebugId = 1;

@immutable
class TerminalPageConfig {
  const TerminalPageConfig({
    required this.accessToken,
    required this.deviceId,
    required this.sessionId,
  });

  // UI presentation flags are intentionally excluded so every entry point
  // shares the same terminal workspace for a given authenticated session.
  //
  // 这里只在“本地 desktop terminal workspace”里忽略 deviceId：Desktop
  // 启动期 TerminalPage 会先拿到 null deviceId，随后再从 settings.sync 收到
  // 真正的 deviceId。如果把这两个状态视为不同 provider family key，会在
  // 同一个页面生命周期内创建第二个 TerminalViewModel，重现 duplicate local
  // websocket / duplicate attach 问题。
  //
  // 但 remote workspace 仍然需要按 deviceId 隔离：同一个 sessionId 下切换
  // 不同设备时，list/create/attach 都是 device-scoped 的，不能继续复用旧 VM。
  final String accessToken;
  final String? deviceId;
  final String? sessionId;

  String get _providerIdentityDeviceId {
    // 本地 desktop workspace 没有 remote sessionId；这里把 bootstrap 期
    // null -> real-device 的切换折叠成同一个 family key。只要 sessionId
    // 存在，就说明当前 terminal workspace 属于 remote session 语义，必须
    // 保留 deviceId 作为 identity，避免切换远端设备后还复用旧 VM。
    if (sessionId == null) {
      return '';
    }
    return deviceId ?? '';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TerminalPageConfig &&
            runtimeType == other.runtimeType &&
            accessToken == other.accessToken &&
            _providerIdentityDeviceId == other._providerIdentityDeviceId &&
            sessionId == other.sessionId;
  }

  @override
  int get hashCode => Object.hash(accessToken, _providerIdentityDeviceId, sessionId);
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

final terminalViewModelProvider = StateNotifierProvider.autoDispose
    .family<TerminalViewModel, TerminalState, TerminalPageConfig>((
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
