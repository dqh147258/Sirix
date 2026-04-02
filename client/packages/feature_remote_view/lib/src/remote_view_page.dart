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
    final palette = context.freeloom;
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
    final palette = context.freeloom;
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
    final palette = context.freeloom;

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

class _RemoteWorkspaceView extends StatelessWidget {
  const _RemoteWorkspaceView({
    required this.state,
    required this.streamState,
    required this.streamController,
    required this.vm,
    required this.accessToken,
  });

  final RemoteViewState state;
  final RemoteStreamState streamState;
  final RemoteStreamController streamController;
  final RemoteViewViewModel vm;
  final String accessToken;

  @override
  Widget build(BuildContext context) {
    final selectedSnapshot = _selectedSnapshot(state);
    final selectedScreenTitle = _selectedScreenTitle(context, state, selectedSnapshot);

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 90),
      children: [
        _RemoteHeader(
          title: selectedScreenTitle,
          subtitle: context.l10n.remoteDesktopTitle,
          liveActive: streamState.connected,
          onTapTitle: () => vm.openMonitorPicker(accessToken: accessToken),
        ),
        _RemoteDisplayCard(
          state: state,
          streamState: streamState,
          streamController: streamController,
          selectedSnapshot: selectedSnapshot,
          preferLiveOnly: true,
          placeholderLabel: state.sessionId == null
              ? null
              : context.l10n.waitingScreenFrame(
                  state.sessionId!,
                  state.sessionState ?? 'connecting',
                ),
          onToggleFullscreen: () => vm.rotate(ViewOrientationMode.landscape),
        ),
        SizedBox(
          height: 360,
          child: TerminalPage(
            accessToken: accessToken,
            deviceId: state.deviceId,
            allowCreate: false,
            showHeader: false,
            compact: true,
          ),
        ),
      ],
    );
  }
}

class _RemoteMonitorView extends StatelessWidget {
  const _RemoteMonitorView({
    required this.state,
    required this.streamState,
    required this.streamController,
    required this.vm,
    required this.accessToken,
  });

  final RemoteViewState state;
  final RemoteStreamState streamState;
  final RemoteStreamController streamController;
  final RemoteViewViewModel vm;
  final String accessToken;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selectedSnapshot = _selectedSnapshot(state);
    final selectedScreenTitle = _selectedScreenTitle(context, state, selectedSnapshot);

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 90),
      children: [
        _RemoteHeader(
          title: selectedScreenTitle,
          subtitle: l10n.displayDetectedLabel(state.snapshots.length),
          liveActive: streamState.connected,
          onTapTitle: () => vm.openMonitorPicker(accessToken: accessToken),
        ),
        _RemoteDisplayCard(
          state: state,
          streamState: streamState,
          streamController: streamController,
          selectedSnapshot: selectedSnapshot,
          preferLiveOnly: true,
          placeholderLabel: state.sessionId == null
              ? null
              : l10n.waitingScreenFrame(
                  state.sessionId!,
                  state.sessionState ?? 'connecting',
                ),
          onToggleFullscreen: () => vm.rotate(ViewOrientationMode.landscape),
        ),
        _MonitorStrip(
          state: state,
          accessToken: accessToken,
          vm: vm,
          selectedSnapshot: selectedSnapshot,
        ),
      ],
    );
  }
}

class _RemoteHeader extends StatelessWidget {
  const _RemoteHeader({
    required this.title,
    required this.subtitle,
    required this.liveActive,
    this.onTapTitle,
  });

  final String title;
  final String subtitle;
  final bool liveActive;
  final VoidCallback? onTapTitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final titleContent = Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: palette.surfaceRaised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Icon(Icons.desktop_windows_rounded, size: 18, color: palette.primaryBright),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 18),
                    ),
                  ),
                  if (onTapTitle != null) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.keyboard_arrow_down_rounded, color: palette.primaryBright),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF10141A).withValues(alpha: 0.96),
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTapTitle,
              borderRadius: BorderRadius.circular(14),
              child: titleContent,
            ),
          ),
          const SizedBox(width: 12),
          _LiveBadge(active: liveActive),
        ],
      ),
    );
  }
}

class _RemoteDisplayCard extends StatelessWidget {
  const _RemoteDisplayCard({
    required this.state,
    required this.streamState,
    required this.streamController,
    required this.selectedSnapshot,
    this.preferLiveOnly = false,
    this.placeholderLabel,
    this.onToggleFullscreen,
  });

  final RemoteViewState state;
  final RemoteStreamState streamState;
  final RemoteStreamController streamController;
  final ScreenSnapshot? selectedSnapshot;
  final bool preferLiveOnly;
  final String? placeholderLabel;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0E1217),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: selectedSnapshot == null
                  ? 16 / 9
                  : selectedSnapshot!.width / selectedSnapshot!.height,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                      child: _RemoteSurface(
                        streamController: streamController,
                        selectedSnapshot: selectedSnapshot,
                        preferLiveOnly: preferLiveOnly,
                        placeholderLabel: placeholderLabel,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.34),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.sync_rounded, size: 14, color: palette.secondary),
                          const SizedBox(width: 6),
                          Text(
                            l10n.syncedLabel,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (onToggleFullscreen != null)
                    Positioned(
                      right: 14,
                      bottom: 14,
                      child: _GlassDisplayActionButton(
                        icon: Icons.fullscreen_rounded,
                        onPressed: onToggleFullscreen!,
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 14,
                    child: Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.28),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _MetricColumn(label: l10n.latencyLabel, value: '12ms'),
                                const SizedBox(width: 20),
                                _MetricColumn(label: 'FPS', value: '60'),
                                const SizedBox(width: 20),
                                _MetricColumn(label: l10n.bitrateLabel, value: '15Mbps'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF151A1F),
                border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
              ),
              child: Row(
                children: [
                  Text(
                    state.selectedScreenId ?? l10n.mainDisplayLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.primaryBright,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  Text(
                    streamState.connected ? l10n.connected : l10n.disconnected,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricColumn extends StatelessWidget {
  const _MetricColumn({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: palette.secondary,
                fontWeight: FontWeight.w700,
                fontSize: 10,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'JetBrains Mono',
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }
}

class _RemoteSurface extends StatelessWidget {
  const _RemoteSurface({
    required this.streamController,
    required this.selectedSnapshot,
    this.preferLiveOnly = false,
    this.placeholderLabel,
  });

  final RemoteStreamController streamController;
  final ScreenSnapshot? selectedSnapshot;
  final bool preferLiveOnly;
  final String? placeholderLabel;

  @override
  Widget build(BuildContext context) {
    final renderer = streamController.remoteRenderer;
    if (renderer != null && renderer.srcObject != null) {
      return RTCVideoView(renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);
    }

    if (!preferLiveOnly && selectedSnapshot != null) {
      return _SnapshotPreview(snapshot: selectedSnapshot!);
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF214A86),
            Color(0xFF183E72),
          ],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.desktop_windows_rounded, size: 72, color: Colors.white24),
              if (placeholderLabel != null) ...[
                const SizedBox(height: 14),
                Text(
                  placeholderLabel!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white60,
                        fontFamily: 'JetBrains Mono',
                        height: 1.5,
                      ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FullscreenRemoteViewer extends StatelessWidget {
  const _FullscreenRemoteViewer({
    required this.state,
    required this.streamState,
    required this.streamController,
    required this.vm,
    required this.accessToken,
  });

  final RemoteViewState state;
  final RemoteStreamState streamState;
  final RemoteStreamController streamController;
  final RemoteViewViewModel vm;
  final String accessToken;

  @override
  Widget build(BuildContext context) {
    final selectedSnapshot = _selectedSnapshot(state);
    final selectedScreenTitle = _selectedScreenTitle(context, state, selectedSnapshot);

    return Stack(
      children: [
        Positioned.fill(
          child: _RemoteSurface(
            streamController: streamController,
            selectedSnapshot: selectedSnapshot,
            preferLiveOnly: true,
            placeholderLabel: state.sessionId == null
                ? null
                : context.l10n.waitingScreenFrame(
                    state.sessionId!,
                    state.sessionState ?? 'connecting',
                  ),
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: SafeArea(
            child: Row(
              children: [
                _FullscreenActionButton(
                  icon: Icons.fullscreen_exit_rounded,
                  onPressed: () => vm.rotate(ViewOrientationMode.portrait),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FullscreenTitleButton(
                    title: selectedScreenTitle,
                    onPressed: () => vm.openMonitorPicker(accessToken: accessToken),
                  ),
                ),
                const SizedBox(width: 8),
                _FullscreenActionButton(
                  icon: Icons.refresh_rounded,
                  onPressed: () => vm.loadSnapshots(accessToken: accessToken),
                ),
                const SizedBox(width: 8),
                _FullscreenActionButton(
                  icon: Icons.close_rounded,
                  onPressed: () => vm.disconnect(accessToken: accessToken),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 18,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MetricColumn(label: context.l10n.latencyLabel, value: '12ms'),
                  const SizedBox(width: 20),
                  _MetricColumn(label: 'FPS', value: '60'),
                  const SizedBox(width: 20),
                  _MetricColumn(label: context.l10n.bitrateLabel, value: '15Mbps'),
                ],
              ),
            ),
          ),
        ),
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

class _MonitorStrip extends StatelessWidget {
  const _MonitorStrip({
    required this.state,
    required this.accessToken,
    required this.vm,
    required this.selectedSnapshot,
  });

  final RemoteViewState state;
  final String accessToken;
  final RemoteViewViewModel vm;
  final ScreenSnapshot? selectedSnapshot;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        decoration: BoxDecoration(
          color: const Color(0xFF0F141A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  l10n.monitors.toUpperCase(),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16),
                ),
                const Spacer(),
                Text(
                  l10n.displayDetectedLabel(state.snapshots.length),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                        fontFamily: 'JetBrains Mono',
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (state.snapshots.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  l10n.waitingScreenFrame(
                    state.sessionId ?? '-',
                    state.sessionState ?? 'connecting',
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                        fontFamily: 'JetBrains Mono',
                        height: 1.5,
                      ),
                ),
              )
            else
              SizedBox(
                height: 170,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: state.snapshots.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final snapshot = state.snapshots[index];
                    final active = snapshot.screenId == state.selectedScreenId ||
                        (state.selectedScreenId == null &&
                            selectedSnapshot != null &&
                            snapshot.screenId == selectedSnapshot!.screenId);
                    return _MonitorPreviewCard(
                      snapshot: snapshot,
                      active: active,
                      onTap: () => vm.selectScreen(
                        accessToken: accessToken,
                        screenId: snapshot.screenId,
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MonitorPreviewCard extends StatelessWidget {
  const _MonitorPreviewCard({
    required this.snapshot,
    required this.active,
    required this.onTap,
  });

  final ScreenSnapshot snapshot;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 188,
        decoration: BoxDecoration(
          color: active ? palette.primaryBright.withValues(alpha: 0.06) : const Color(0xFF151A20),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? palette.primaryBright : Colors.white.withValues(alpha: 0.05),
            width: active ? 1.3 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                child: _SnapshotPreview(snapshot: snapshot),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snapshot.name.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${snapshot.width} x ${snapshot.height}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                          fontFamily: 'JetBrains Mono',
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonitorPickerOverlay extends StatelessWidget {
  const _MonitorPickerOverlay({
    required this.state,
    required this.accessToken,
    required this.vm,
  });

  final RemoteViewState state;
  final String accessToken;
  final RemoteViewViewModel vm;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.62),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: DecoratedBox(
                  decoration: AppTheme.glassDecoration(
                    context,
                    radius: 18,
                    fillColor: const Color(0xF0101419),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.selectActiveDisplayTitle,
                                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 28),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    l10n.displayDetectedLabel(state.snapshots.length),
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: palette.textMuted,
                                          fontFamily: 'JetBrains Mono',
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => vm.setMonitorPickerVisible(false),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                          itemCount: state.snapshots.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 16),
                          itemBuilder: (context, index) {
                            final snapshot = state.snapshots[index];
                            final active = snapshot.screenId == state.selectedScreenId;
                            return InkWell(
                              onTap: () => vm.selectScreen(
                                accessToken: accessToken,
                                screenId: snapshot.screenId,
                              ),
                              borderRadius: BorderRadius.circular(14),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: active
                                      ? palette.primaryBright.withValues(alpha: 0.06)
                                      : const Color(0xFF0E1115),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: active ? palette.primaryBright : Colors.white.withValues(alpha: 0.05),
                                    width: active ? 1.4 : 1,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    AspectRatio(
                                      aspectRatio: snapshot.width / snapshot.height,
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child: ClipRRect(
                                              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                                              child: _SnapshotPreview(snapshot: snapshot),
                                            ),
                                          ),
                                          if (active)
                                            Positioned.fill(
                                              child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                  color: palette.primaryBright.withValues(alpha: 0.08),
                                                ),
                                                child: Center(
                                                  child: Container(
                                                    width: 72,
                                                    height: 72,
                                                    decoration: BoxDecoration(
                                                      color: Colors.black.withValues(alpha: 0.42),
                                                      borderRadius: BorderRadius.circular(20),
                                                    ),
                                                    child: Icon(Icons.check_circle_rounded, color: palette.primaryBright, size: 38),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(14),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(snapshot.name.toUpperCase(), style: Theme.of(context).textTheme.titleMedium),
                                                const SizedBox(height: 4),
                                                Text(
                                                  '${snapshot.width} x ${snapshot.height} @ 60Hz',
                                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                        color: palette.primaryBright,
                                                        fontFamily: 'JetBrains Mono',
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            active ? l10n.connected.toUpperCase() : l10n.standbyLabel.toUpperCase(),
                                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                  color: active ? palette.textPrimary : palette.textMuted,
                                                  fontFamily: 'JetBrains Mono',
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenActionButton extends StatelessWidget {
  const _FullscreenActionButton({
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(999),
      child: IconButton(
        onPressed: onPressed,
        color: Colors.white,
        icon: Icon(icon),
      ),
    );
  }
}

class _FullscreenTitleButton extends StatelessWidget {
  const _FullscreenTitleButton({
    required this.title,
    this.onPressed,
  });

  final String title;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Icon(Icons.desktop_windows_rounded, size: 18, color: palette.primaryBright),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (onPressed != null) ...[
                const SizedBox(width: 6),
                Icon(Icons.keyboard_arrow_down_rounded, color: palette.primaryBright),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassDisplayActionButton extends StatelessWidget {
  const _GlassDisplayActionButton({
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Material(
          color: Colors.black.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Icon(icon, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

String _selectedScreenTitle(
  BuildContext context,
  RemoteViewState state,
  ScreenSnapshot? selectedSnapshot,
) {
  return selectedSnapshot?.name.toUpperCase() ??
      state.selectedScreenId?.toUpperCase() ??
      context.l10n.mainDisplayLabel;
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({
    required this.active,
  });

  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: active ? palette.primaryBright : palette.textMuted,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'LIVE',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: active ? palette.primaryBright : palette.textMuted,
                ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotPreview extends StatelessWidget {
  const _SnapshotPreview({
    required this.snapshot,
  });

  final ScreenSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    try {
      final bytes = base64Decode(snapshot.previewBase64);
      return Image.memory(bytes, fit: BoxFit.cover);
    } catch (_) {
      return DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF28323C), Color(0xFF12171E)],
          ),
        ),
        child: const Center(
          child: Icon(Icons.desktop_windows_outlined, color: Colors.white24, size: 42),
        ),
      );
    }
  }
}

ScreenSnapshot? _selectedSnapshot(RemoteViewState state) {
  final selectedScreenId = state.selectedScreenId;
  if (selectedScreenId != null) {
    for (final snapshot in state.snapshots) {
      if (snapshot.screenId == selectedScreenId) {
        return snapshot;
      }
    }
  }
  if (state.snapshots.isNotEmpty) {
    return state.snapshots.first;
  }
  return null;
}
