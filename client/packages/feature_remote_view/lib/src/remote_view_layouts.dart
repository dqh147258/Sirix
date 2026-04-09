part of 'remote_view_page.dart';

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

    return Column(
      children: [
        _RemoteHeader(
          title: selectedScreenTitle,
          subtitle: context.l10n.remoteDesktopTitle,
          liveActive: streamState.connected,
          onTapTitle: () => vm.openMonitorPicker(accessToken: accessToken),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
            child: Column(
              children: [
                Expanded(
                  flex: 4,
                  child: _RemoteDisplayCard(
                    state: state,
                    streamState: streamState,
                    streamController: streamController,
                    selectedSnapshot: selectedSnapshot,
                    preferLiveOnly: true,
                    expandSurface: true,
                    padding: EdgeInsets.zero,
                    placeholderLabel: state.sessionId == null
                        ? null
                        : context.l10n.waitingScreenFrame(
                            state.sessionId!,
                            state.sessionState ?? 'connecting',
                          ),
                    onToggleFullscreen: () => vm.rotate(ViewOrientationMode.landscape),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  flex: 5,
                  child: TerminalPage(
                    accessToken: accessToken,
                    deviceId: state.deviceId,
                    sessionId: state.sessionId,
                    allowCreate: state.deviceId != null && state.sessionId != null,
                    showHeader: false,
                    compact: true,
                    fullBleed: true,
                  ),
                ),
              ],
            ),
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
    final palette = context.sirix;
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

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({
    required this.active,
  });

  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

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
