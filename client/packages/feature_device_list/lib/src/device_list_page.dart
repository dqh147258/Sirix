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
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.nodeSelectionTitle.toUpperCase(),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontFamily: 'Space Grotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 24,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${state.devices.length} DEVICES FOUND',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                          fontFamily: 'JetBrains Mono',
                          fontSize: 12,
                        ),
                  ),
                ],
              ),
              InkWell(
                onTap: () => vm.load(widget.accessToken),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.15)),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.sync_rounded,
                      size: 18,
                      color: palette.textSecondary,
                    ),
                  ),
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
                  border:
                      Border.all(color: palette.error.withValues(alpha: 0.24)),
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
                Icon(Icons.link_off_rounded,
                    color: palette.textMuted, size: 28),
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
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF1E2125), // Surface container high
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 4,
            right: 4,
            child: Icon(
              Icons.desktop_windows_outlined,
              size: 72,
              color: Colors.white.withValues(alpha: 0.04),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
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
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontFamily: 'Space Grotesk',
                                  fontWeight: FontWeight.w700,
                                  fontSize: 20,
                                  color: palette.textPrimary,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'IP: ${_deviceIpHint(device)}',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: palette.textMuted,
                                      fontFamily: 'JetBrains Mono',
                                      fontSize: 12,
                                    ),
                          ),
                        ],
                      ),
                    ),
                    _StatusBadge(online: device.online),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      l10n.autoApprove,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: palette.textMuted),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      value: device.autoApproveScreenShare,
                      onChanged: onToggleAutoApprove,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08)),
                          ),
                          child: Icon(
                            device.platform == 'windows'
                                ? Icons.desktop_windows_rounded
                                : device.platform == 'macos'
                                    ? Icons.desktop_mac_rounded
                                    : Icons.computer_rounded,
                            size: 14,
                            color: palette.secondary,
                          ),
                        ),
                      ],
                    ),
                    InkWell(
                      onTap: onConnect,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 10),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: onConnect != null
                                ? [
                                    palette.primary,
                                    palette.primaryBright
                                        .withValues(alpha: 0.8),
                                  ]
                                : [
                                    palette.surfaceRaised,
                                    palette.surfaceRaised,
                                  ],
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          l10n.connect.toUpperCase(),
                          style: TextStyle(
                            color: onConnect != null
                                ? const Color(0xFF08120D)
                                : palette.textMuted,
                            fontWeight: FontWeight.w800,
                            fontFamily: 'Space Grotesk',
                            fontSize: 14,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _deviceIpHint(DeviceSummary device) {
    final hash = device.id.hashCode.abs();
    final last = (hash % 200) + 20;
    return device.platform == 'windows'
        ? '192.168.1.$last'
        : '10.0.0.${last % 80 + 10}';
  }
}

class _StatusBadge extends StatefulWidget {
  const _StatusBadge({
    required this.online,
  });

  final bool online;

  @override
  State<_StatusBadge> createState() => _StatusBadgeState();
}

class _StatusBadgeState extends State<_StatusBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _anim = Tween<double>(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    if (widget.online) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _StatusBadge onlineParam) {
    if (widget.online && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.online && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0.4;
    }
    super.didUpdateWidget(onlineParam);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    if (!widget.online) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: palette.textMuted,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              context.l10n.offline.toUpperCase(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'JetBrains Mono',
                    fontSize: 10,
                    letterSpacing: 1.0,
                  ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.background.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _anim,
            builder: (context, child) {
              return Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: palette.primaryBright,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: palette.primaryBright
                          .withValues(alpha: _anim.value * 0.6),
                      blurRadius: 10 * _anim.value,
                      spreadRadius: 2 * _anim.value,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          Text(
            context.l10n.online.toUpperCase(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.primaryBright,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrains Mono',
                  fontSize: 10,
                  letterSpacing: 1.0,
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
