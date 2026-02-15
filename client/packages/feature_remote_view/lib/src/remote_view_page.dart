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

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          if (connectedSession != null && state.sessionId == null)
            ElevatedButton(
              onPressed: () => vm.attachSession(
                sessionId: connectedSession!.sessionId,
                deviceId: connectedSession!.targetDeviceId,
                accessToken: accessToken,
              ),
              child: const Text('附加会话'),
            ),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio:
                state.orientationMode == ViewOrientationMode.landscape ? 16 / 9 : 9 / 16,
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: Text(
                state.sessionId == null
                    ? '未连接会话'
                    : '屏幕共享中\n会话: ${state.sessionId}\n状态: ${state.sessionState ?? 'connecting'}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
          if (state.lastEventType != null) ...[
            const SizedBox(height: 8),
            Text('最近事件: ${state.lastEventType}'),
          ],
          if (state.backgroundPauseDeadline != null) ...[
            const SizedBox(height: 8),
            Text('后台暂停截止时间: ${state.backgroundPauseDeadline}'),
          ],
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
                  child: const Text('竖屏'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => vm.rotate(ViewOrientationMode.landscape),
                  child: const Text('横屏'),
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
          if (state.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              state.errorMessage!,
              style: const TextStyle(color: Colors.red),
            ),
          ],
        ],
      ),
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
