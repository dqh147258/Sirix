part of 'remote_view_page.dart';

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
