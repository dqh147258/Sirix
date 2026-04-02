import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

import 'package:app_core/app_core.dart';

import 'desktop_authorize_state.dart';
import 'desktop_authorize_view_model.dart';

part 'desktop_authorize_components.dart';

class DesktopAuthorizePage extends ConsumerStatefulWidget {
  const DesktopAuthorizePage({
    super.key,
    required this.authSession,
  });

  final AuthSession? authSession;

  @override
  ConsumerState<DesktopAuthorizePage> createState() => _DesktopAuthorizePageState();
}

class DesktopAuthorizeBootstrap extends ConsumerStatefulWidget {
  const DesktopAuthorizeBootstrap({
    super.key,
    required this.authSession,
  });

  final AuthSession? authSession;

  @override
  ConsumerState<DesktopAuthorizeBootstrap> createState() => _DesktopAuthorizeBootstrapState();
}

class _DesktopAuthorizeBootstrapState extends ConsumerState<DesktopAuthorizeBootstrap> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final vm = ref.read(desktopAuthorizeViewModelProvider.notifier);
      await vm.bindAuthSession(widget.authSession);
      await vm.connect();
    });
  }

  @override
  void didUpdateWidget(covariant DesktopAuthorizeBootstrap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authSession?.accessToken != widget.authSession?.accessToken) {
      unawaited(
        () async {
          final vm = ref.read(desktopAuthorizeViewModelProvider.notifier);
          await vm.bindAuthSession(widget.authSession);
          await vm.connect();
        }(),
      );
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _DesktopAuthorizePageState extends ConsumerState<DesktopAuthorizePage> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopAuthorizeViewModelProvider);
    final mediaState = ref.watch(desktopMediaControllerProvider);
    final palette = context.sirix;
    final l10n = context.l10n;

    final vm = ref.read(desktopAuthorizeViewModelProvider.notifier);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F13),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _TechGridPainter(color: palette.primaryBright.withValues(alpha: 0.08)),
            ),
          ),
          ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  _StatusCard(
                    title: l10n.localWs,
                    value: state.connected ? l10n.localDesktopConnected : l10n.localDesktopDisconnected,
                    active: state.connected,
                    trailing: TextButton(
                      onPressed: vm.reconnect,
                      child: Text(l10n.reconnect),
                    ),
                  ),
                  _StatusCard(
                    title: l10n.sharingState,
                    value: mediaState.sharing
                        ? l10n.realMediaSharing
                        : mediaState.initializing
                            ? l10n.realMediaInitializing
                            : l10n.realMediaIdle,
                    active: mediaState.sharing,
                  ),
                  _StatusCard(
                    title: l10n.pendingRequests,
                    value: '${state.pendingRequests.length}',
                    active: state.pendingRequests.isNotEmpty,
                  ),
                ],
              ),
              if (state.connecting || state.mediaInitializing || state.registeringDevice) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: const LinearProgressIndicator(minHeight: 4),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF14191F).withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.desktopAuthorizeIntro, style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _MetaPill(label: 'device_id', value: state.deviceId ?? '-'),
                        _MetaPill(label: 'local_ws_port', value: '${state.localWsPort ?? '-'}'),
                        _MetaPill(label: 'backend_device', value: state.registeredDeviceId ?? '-'),
                        _MetaPill(label: 'shared_screen', value: mediaState.sharedScreenId ?? '-'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.autoApproveShare),
                      subtitle: Text(l10n.deviceLevelDefaultOff),
                      value: state.autoApprove,
                      onChanged: vm.setAutoApprove,
                    ),
                    if (state.lastEventType != null)
                      Text(
                        '${l10n.recentEvent}: ${state.lastEventType}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                              fontFamily: 'JetBrains Mono',
                            ),
                      ),
                  ],
                ),
              ),
              if (state.errorMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: palette.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: palette.error.withValues(alpha: 0.28)),
                  ),
                  child: Text(state.errorMessage!, style: TextStyle(color: palette.error)),
                ),
              ],
              if (state.pendingRequests.isEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF14191F).withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                  ),
                  child: Text(l10n.noPendingRequests),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class DesktopAuthorizeRequestOverlay extends ConsumerWidget {
  const DesktopAuthorizeRequestOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(desktopAuthorizeViewModelProvider);
    if (state.pendingRequests.isEmpty) {
      return const SizedBox.shrink();
    }

    final vm = ref.read(desktopAuthorizeViewModelProvider.notifier);
    final request = state.pendingRequests.first;

    return SizedBox.expand(
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.58)),
        child: SafeArea(
          minimum: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: DecoratedBox(
                    decoration: AppTheme.glassDecoration(
                      context,
                      radius: 18,
                      fillColor: const Color(0xF015191D),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: _AuthorizeModal(
                        request: request,
                        onApprove: () => vm.approve(request.sessionId),
                        onReject: () => vm.reject(request.sessionId),
                      ),
                    ),
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
