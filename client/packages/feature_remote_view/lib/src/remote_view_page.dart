import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

import 'remote_view_state.dart';
import 'remote_view_view_model.dart';

part 'remote_view_layouts.dart';
part 'remote_view_surface.dart';
part 'remote_view_overlays.dart';

enum RemoteViewLayout {
  workspace,
  monitor,
}

class RemoteViewPage extends ConsumerWidget {
  const RemoteViewPage({
    super.key,
    required this.accessToken,
    this.connectedSession,
    this.layout = RemoteViewLayout.workspace,
  });

  final String accessToken;
  final RemoteSessionSummary? connectedSession;
  final RemoteViewLayout layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(remoteViewViewModelProvider);
    final vm = ref.read(remoteViewViewModelProvider.notifier);
    final streamState = ref.watch(remoteStreamControllerProvider);
    final streamController = ref.read(remoteStreamControllerProvider.notifier);
    final pendingApproval = state.sessionState == 'pending_approval';

    final fullscreenViewer =
        state.sessionId != null && !pendingApproval && state.orientationMode == ViewOrientationMode.landscape;
    if (fullscreenViewer) {
      return _FullscreenRemoteViewer(
        state: state,
        streamState: streamState,
        streamController: streamController,
        vm: vm,
        accessToken: accessToken,
      );
    }

    return Stack(
      children: [
        if (pendingApproval)
          _PendingAuthorizationView(
            state: state,
            onCancel: () => vm.disconnect(accessToken: accessToken),
          )
        else if (state.sessionId == null)
          _RemoteIdleView(
            connectedSession: connectedSession,
            onAttach: connectedSession == null
                ? null
                : () => vm.attachSession(
                      sessionId: connectedSession!.sessionId,
                      deviceId: connectedSession!.targetDeviceId,
                      accessToken: accessToken,
                      initialState: connectedSession!.state,
                    ),
          )
        else
          switch (layout) {
            RemoteViewLayout.workspace => _RemoteWorkspaceView(
                state: state,
                streamState: streamState,
                streamController: streamController,
                vm: vm,
                accessToken: accessToken,
              ),
            RemoteViewLayout.monitor => _RemoteMonitorView(
                state: state,
                streamState: streamState,
                streamController: streamController,
                vm: vm,
                accessToken: accessToken,
              ),
          },
        if (state.monitorPickerVisible)
          _MonitorPickerOverlay(
            state: state,
            accessToken: accessToken,
            vm: vm,
          ),
      ],
    );
  }
}

class _RemoteIdleView extends StatelessWidget {
  const _RemoteIdleView({
    required this.connectedSession,
    required this.onAttach,
  });

  final RemoteSessionSummary? connectedSession;
  final VoidCallback? onAttach;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.remoteWorkspaceTitle,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 30),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.remoteWorkspaceIdleHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.textMuted),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.live_tv_rounded, size: 48, color: palette.primaryBright),
                      const SizedBox(height: 16),
                      Text(
                        l10n.notConnectedSession,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.selectNodeFirstHint,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                              height: 1.5,
                            ),
                      ),
                      if (onAttach != null) ...[
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: onAttach,
                          icon: const Icon(Icons.link_rounded),
                          label: Text(l10n.attachSession),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingAuthorizationView extends StatelessWidget {
  const _PendingAuthorizationView({
    required this.state,
    required this.onCancel,
  });

  final RemoteViewState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      children: [
        Container(
          width: 160,
          height: 160,
          margin: const EdgeInsets.only(top: 8, bottom: 28),
          decoration: BoxDecoration(
            color: const Color(0xFF1D2328),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.desktop_windows_rounded, size: 64, color: palette.primaryBright),
              Positioned(
                right: 14,
                top: 14,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: palette.surfaceRaised,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.wifi_tethering_rounded, color: palette.secondary, size: 20),
                ),
              ),
              Positioned(
                bottom: 18,
                child: Text(
                  state.deviceId ?? 'REMOTE-NODE',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.primaryBright,
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
        ),
        Text(
          l10n.requestingAccessTitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 34),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.requestingAccessSubtitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.textMuted),
        ),
        const SizedBox(height: 28),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: 0.75,
            minHeight: 24,
            color: palette.primaryBright,
            backgroundColor: Colors.black.withValues(alpha: 0.28),
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LogLine(text: '[09:44:12] ${l10n.requestLogHandshake}'),
              _LogLine(text: '[09:44:13] ${l10n.requestLogValidated}'),
              _LogLine(text: '[09:44:15] ${l10n.requestLogAwaitingManualApproval}'),
            ],
          ),
        ),
        const SizedBox(height: 26),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: onCancel,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(l10n.cancelRequest),
          ),
        ),
      ],
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({
    required this.text,
  });

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: palette.primaryBright.withValues(alpha: 0.72),
              fontFamily: 'JetBrains Mono',
            ),
      ),
    );
  }
}
