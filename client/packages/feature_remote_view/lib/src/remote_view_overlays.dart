part of 'remote_view_page.dart';

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
