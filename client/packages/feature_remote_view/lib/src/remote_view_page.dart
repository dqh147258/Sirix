import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

import 'remote_view_state.dart';
import 'remote_view_view_model.dart';

class RemoteViewPage extends ConsumerWidget {
  const RemoteViewPage({
    super.key,
    required this.accessToken,
    this.connectedSession,
  });

  final String accessToken;
  final RemoteSessionSummary? connectedSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(remoteViewViewModelProvider);
    final vm = ref.read(remoteViewViewModelProvider.notifier);
    final streamState = ref.watch(remoteStreamControllerProvider);
    final streamController = ref.read(remoteStreamControllerProvider.notifier);

    final fullscreenViewer =
        state.sessionId != null && state.orientationMode == ViewOrientationMode.landscape;
    if (fullscreenViewer) {
      return _FullscreenRemoteViewer(
        state: state,
        streamState: streamState,
        streamController: streamController,
        vm: vm,
        accessToken: accessToken,
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          if (connectedSession != null && state.sessionId == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => vm.attachSession(
                    sessionId: connectedSession!.sessionId,
                    deviceId: connectedSession!.targetDeviceId,
                    accessToken: accessToken,
                    initialState: connectedSession!.state,
                  ),
                  child: const Text('附加会话'),
                ),
              ),
            ),
          if (state.errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                state.errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          const SizedBox(height: 8),
          const TabBar(
            tabs: [
              Tab(text: '查看'),
              Tab(text: '设置'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _RemoteViewerTab(
                  state: state,
                  streamState: streamState,
                  streamController: streamController,
                ),
                _RemoteSettingsTab(
                  state: state,
                  vm: vm,
                  accessToken: accessToken,
                ),
              ],
            ),
          ),
        ],
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
    return Stack(
      children: [
        Positioned.fill(
          child: _RemoteViewerTab(
            state: state,
            streamState: streamState,
            streamController: streamController,
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
                  icon: Icons.screen_rotation_alt_outlined,
                  tooltip: '退出横屏',
                  onPressed: () => vm.rotate(ViewOrientationMode.portrait),
                ),
                const Spacer(),
                _FullscreenActionButton(
                  icon: Icons.refresh,
                  tooltip: '刷新快照',
                  onPressed: () => vm.loadSnapshots(accessToken: accessToken),
                ),
                const SizedBox(width: 8),
                _FullscreenActionButton(
                  icon: Icons.close,
                  tooltip: '断开会话',
                  onPressed: () => vm.disconnect(accessToken: accessToken),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RemoteViewerTab extends StatelessWidget {
  const _RemoteViewerTab({
    required this.state,
    required this.streamState,
    required this.streamController,
  });

  final RemoteViewState state;
  final RemoteStreamState streamState;
  final RemoteStreamController streamController;

  @override
  Widget build(BuildContext context) {
    final selected = _selectedSnapshot(state);
    final isLandscape = state.orientationMode == ViewOrientationMode.landscape;

    final viewer = Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: _SharedScreenSurface(
        state: state,
        streamState: streamState,
        streamController: streamController,
        selectedSnapshot: selected,
      ),
    );

    if (isLandscape && state.sessionId != null) {
      return SizedBox.expand(child: viewer);
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        AspectRatio(
          aspectRatio: isLandscape ? 16 / 9 : 9 / 16,
          child: viewer,
        ),
        const SizedBox(height: 10),
        Text('会话: ${state.sessionId ?? '-'}'),
        Text('状态: ${state.sessionState ?? '未连接'}'),
        Text('屏幕: ${state.selectedScreenId ?? '-'}'),
      ],
    );
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
}

class _FullscreenActionButton extends StatelessWidget {
  const _FullscreenActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(999),
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        color: Colors.white,
        icon: Icon(icon),
      ),
    );
  }
}

class _RemoteSettingsTab extends StatelessWidget {
  const _RemoteSettingsTab({
    required this.state,
    required this.vm,
    required this.accessToken,
  });

  final RemoteViewState state;
  final RemoteViewViewModel vm;
  final String accessToken;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (state.lastEventType != null) Text('最近事件: ${state.lastEventType}'),
        if (state.backgroundPauseDeadline != null)
          Text('后台暂停截止时间: ${state.backgroundPauseDeadline}'),
        if (state.lastEventType != null || state.backgroundPauseDeadline != null)
          const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('自动码率'),
              selected: state.autoQuality,
              onSelected: (_) => vm.setAutoQuality(accessToken: accessToken),
            ),
            ChoiceChip(
              label: const Text('480P'),
              selected: !state.autoQuality && state.qualityProfile == QualityProfile.p480,
              onSelected: (_) => vm.setManualQuality(
                accessToken: accessToken,
                profile: QualityProfile.p480,
              ),
            ),
            ChoiceChip(
              label: const Text('720P'),
              selected: !state.autoQuality && state.qualityProfile == QualityProfile.p720,
              onSelected: (_) => vm.setManualQuality(
                accessToken: accessToken,
                profile: QualityProfile.p720,
              ),
            ),
            ChoiceChip(
              label: const Text('1080P'),
              selected: !state.autoQuality && state.qualityProfile == QualityProfile.p1080,
              onSelected: (_) => vm.setManualQuality(
                accessToken: accessToken,
                profile: QualityProfile.p1080,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            const Text('快照刷新:'),
            ChoiceChip(
              label: const Text('3秒'),
              selected: state.snapshotRefreshSeconds == 3,
              onSelected: (_) => vm.setSnapshotRefreshSeconds(seconds: 3),
            ),
            ChoiceChip(
              label: const Text('5秒'),
              selected: state.snapshotRefreshSeconds == 5,
              onSelected: (_) => vm.setSnapshotRefreshSeconds(seconds: 5),
            ),
            ChoiceChip(
              label: const Text('10秒'),
              selected: state.snapshotRefreshSeconds == 10,
              onSelected: (_) => vm.setSnapshotRefreshSeconds(seconds: 10),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => vm.rotate(ViewOrientationMode.portrait),
                child: const Text('竖屏查看'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => vm.rotate(ViewOrientationMode.landscape),
                child: const Text('横屏查看'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => vm.loadSnapshots(accessToken: accessToken),
          child: const Text('刷新屏幕列表'),
        ),
        const SizedBox(height: 8),
        for (final snapshot in state.snapshots)
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(12),
              title: Text(snapshot.name),
              subtitle: Text('${snapshot.width} x ${snapshot.height}'),
              leading: _SnapshotPreview(snapshot: snapshot),
              trailing: state.selectedScreenId == snapshot.screenId
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : null,
              onTap: () => vm.selectScreen(
                accessToken: accessToken,
                screenId: snapshot.screenId,
              ),
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton(
              onPressed: () => vm.onAppBackground(accessToken: accessToken),
              child: const Text('模拟后台'),
            ),
            OutlinedButton(
              onPressed: () => vm.onAppForeground(accessToken: accessToken),
              child: const Text('回到前台'),
            ),
            OutlinedButton(
              onPressed: () => vm.disconnect(accessToken: accessToken),
              child: const Text('断开会话'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SharedScreenSurface extends StatelessWidget {
  const _SharedScreenSurface({
    required this.state,
    required this.streamState,
    required this.streamController,
    required this.selectedSnapshot,
  });

  final RemoteViewState state;
  final RemoteStreamState streamState;
  final RemoteStreamController streamController;
  final ScreenSnapshot? selectedSnapshot;

  @override
  Widget build(BuildContext context) {
    final remoteRenderer = streamController.remoteRenderer;
    if (streamState.remoteVideoActive && remoteRenderer != null) {
      return RTCVideoView(
        remoteRenderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    }

    final snapshot = selectedSnapshot;
    if (snapshot != null && snapshot.previewBase64.isNotEmpty) {
      try {
        final bytes = base64Decode(snapshot.previewBase64);
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _buildFallbackText(),
        );
      } catch (_) {
        return _buildFallbackText();
      }
    }

    return _buildFallbackText();
  }

  Widget _buildFallbackText() {
    return Text(
      state.sessionId == null
          ? '未连接会话'
          : '等待屏幕画面\n会话: ${state.sessionId}\n状态: ${state.sessionState ?? 'connecting'}',
      textAlign: TextAlign.center,
      style: const TextStyle(color: Colors.white),
    );
  }
}

class _SnapshotPreview extends StatelessWidget {
  const _SnapshotPreview({required this.snapshot});

  final ScreenSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final base64Data = snapshot.previewBase64;
    if (base64Data.isEmpty) {
      return _fallbackPreview();
    }

    try {
      final bytes = base64Decode(base64Data);
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          bytes,
          width: 72,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackPreview(),
        ),
      );
    } catch (_) {
      return _fallbackPreview();
    }
  }

  Widget _fallbackPreview() {
    return Container(
      width: 72,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Icon(Icons.monitor_outlined, size: 20),
    );
  }
}
