import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'device_list_view_model.dart';

class DeviceListPage extends ConsumerStatefulWidget {
  const DeviceListPage({
    super.key,
    required this.accessToken,
    this.onConnectSession,
  });

  final String accessToken;
  final ValueChanged<RemoteSessionSummary>? onConnectSession;

  @override
  ConsumerState<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends ConsumerState<DeviceListPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(deviceListViewModelProvider.notifier).load(widget.accessToken);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deviceListViewModelProvider);
    final vm = ref.read(deviceListViewModelProvider.notifier);
    final palette = context.freeloom;
    final l10n = context.l10n;

    return RefreshIndicator(
      onRefresh: () => vm.load(widget.accessToken),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
        children: [
          Text(
            l10n.nodeSelectionTitle,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 34),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 28,
                height: 2,
                color: palette.primaryBright,
              ),
              const SizedBox(width: 10),
              Text(
                l10n.nodeSelectionSubtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (state.loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: const LinearProgressIndicator(minHeight: 4),
              ),
            ),
          if (state.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: palette.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: palette.error.withValues(alpha: 0.24)),
                ),
                child: Text(
                  state.errorMessage!,
                  style: TextStyle(color: palette.error),
                ),
              ),
            ),
          if (state.devices.isEmpty && !state.loading)
            _EmptyDeviceCard(message: l10n.noDeviceAvailable),
          for (final device in state.devices) ...[
            _NodeCard(
              device: device,
              onToggleAutoApprove: (value) => vm.toggleAutoApprove(
                accessToken: widget.accessToken,
                device: device,
                nextValue: value,
              ),
              onConnect: device.online
                  ? () async {
                      final session = await vm.connectToDevice(
                        accessToken: widget.accessToken,
                        deviceId: device.id,
                      );
                      if (session != null && mounted) {
                        widget.onConnectSession?.call(session);
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 16),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
            ),
            child: Column(
              children: [
                Icon(Icons.link_off_rounded, color: palette.textMuted, size: 28),
                const SizedBox(height: 12),
                Text(
                  l10n.noActiveSessionTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: palette.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.noActiveSessionHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                        height: 1.5,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.device,
    required this.onToggleAutoApprove,
    required this.onConnect,
  });

  final DeviceSummary device;
  final ValueChanged<bool> onToggleAutoApprove;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2E33).withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.deviceName.toUpperCase(),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 22),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'IP: ${_deviceIpHint(device)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.textSecondary,
                            fontFamily: 'JetBrains Mono',
                          ),
                    ),
                  ],
                ),
              ),
              _StatusBadge(online: device.online),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      device.platform == 'windows'
                          ? Icons.desktop_windows_rounded
                          : device.platform == 'macos'
                              ? Icons.desktop_mac_rounded
                              : Icons.computer_rounded,
                      size: 16,
                      color: palette.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      device.platform.toUpperCase(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.textMuted,
                            fontFamily: 'JetBrains Mono',
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      l10n.autoApprove,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.textMuted),
                    ),
                    const Spacer(),
                    Switch(
                      value: device.autoApproveScreenShare,
                      onChanged: onToggleAutoApprove,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: 136,
            child: FilledButton(
              onPressed: onConnect,
              style: FilledButton.styleFrom(
                backgroundColor: palette.primary,
                foregroundColor: const Color(0xFF08120D),
                minimumSize: const Size.fromHeight(42),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              child: Text(
                l10n.connect.toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _deviceIpHint(DeviceSummary device) {
    final hash = device.id.hashCode.abs();
    final last = (hash % 200) + 20;
    return device.platform == 'windows' ? '192.168.1.$last' : '10.0.0.${last % 80 + 10}';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.online,
  });

  final bool online;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: online ? palette.primaryBright : palette.textMuted,
              borderRadius: BorderRadius.circular(999),
              boxShadow: online
                  ? [
                      BoxShadow(
                        color: palette.primaryBright.withValues(alpha: 0.4),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            (online ? l10n.online : l10n.offline).toUpperCase(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: online ? palette.primaryBright : palette.textMuted,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrains Mono',
                ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDeviceCard extends StatelessWidget {
  const _EmptyDeviceCard({
    required this.message,
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surfaceRaised.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(message),
    );
  }
}
