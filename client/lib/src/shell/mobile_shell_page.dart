import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_device_list/feature_device_list.dart';
import 'package:feature_remote_view/feature_remote_view.dart';
import 'package:feature_terminal/feature_terminal.dart';

import 'shell_view_model.dart';

class MobileShellPage extends ConsumerStatefulWidget {
  const MobileShellPage({super.key});

  @override
  ConsumerState<MobileShellPage> createState() => _MobileShellPageState();
}

class _MobileShellPageState extends ConsumerState<MobileShellPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      return ref.read(authViewModelProvider('mobile').notifier).initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authViewModelProvider('mobile'));
    final session = authState.session;

    if (!authState.initialized || authState.isInitializing) {
      return const _MobileShellBootstrapScreen();
    }

    if (session == null) {
      return const AuthPage(clientType: 'mobile');
    }

    final shellState = ref.watch(shellViewModelProvider(ShellMode.mobile));
    final shellVm = ref.read(shellViewModelProvider(ShellMode.mobile).notifier);
    final remoteViewState = ref.watch(remoteViewViewModelProvider);
    final fullscreenRemote = shellState.selectedIndex == 1 &&
        remoteViewState.sessionId != null &&
        remoteViewState.orientationMode == ViewOrientationMode.landscape;

    final pages = [
      DeviceListPage(
        accessToken: session.accessToken,
        onConnectSession: (value) {
          shellVm.attachRemoteSession(value);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(remoteViewViewModelProvider.notifier).attachSession(
                  sessionId: value.sessionId,
                  deviceId: value.targetDeviceId,
                  accessToken: session.accessToken,
                  initialState: value.state,
                );
          });
        },
      ),
      RemoteViewPage(
        accessToken: session.accessToken,
        connectedSession: shellState.activeRemoteSession,
      ),
      TerminalPage(
        accessToken: session.accessToken,
        deviceId: shellState.activeRemoteSession?.targetDeviceId ?? remoteViewState.deviceId,
        allowCreate: false,
      ),
      _ShellAccountPage(
        username: session.username,
        onLogout: () {
          ref.read(authViewModelProvider('mobile').notifier).logout();
          shellVm.reset();
        },
      ),
    ];

    if (fullscreenRemote) {
      return Scaffold(body: pages[shellState.selectedIndex]);
    }

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF090C11), Color(0xFF0D1117), Color(0xFF080B10)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xE611151A),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: pages[shellState.selectedIndex],
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: NavigationBar(
          selectedIndex: shellState.selectedIndex,
          onDestinationSelected: shellVm.selectIndex,
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.desktop_windows_outlined),
              selectedIcon: const Icon(Icons.desktop_windows_rounded),
              label: context.l10n.nodesNav,
            ),
            NavigationDestination(
              icon: const Icon(Icons.live_tv_outlined),
              selectedIcon: const Icon(Icons.live_tv_rounded),
              label: context.l10n.monitors,
            ),
            NavigationDestination(
              icon: const Icon(Icons.terminal_rounded),
              selectedIcon: const Icon(Icons.terminal),
              label: context.l10n.terminal,
            ),
            NavigationDestination(
              icon: const Icon(Icons.person_outline_rounded),
              selectedIcon: const Icon(Icons.person_rounded),
              label: context.l10n.account,
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileShellBootstrapScreen extends StatelessWidget {
  const _MobileShellBootstrapScreen();

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Scaffold(
      backgroundColor: const Color(0xFF090C11),
      body: Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: palette.primaryBright,
        ),
      ),
    );
  }
}

class _ShellAccountPage extends StatelessWidget {
  const _ShellAccountPage({
    required this.username,
    required this.onLogout,
  });

  final String username;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 28,
              child: Text(username.isEmpty ? 'F' : username[0].toUpperCase()),
            ),
            const SizedBox(height: 12),
            Text(username, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onLogout,
              icon: const Icon(Icons.logout_rounded),
              label: Text(context.l10n.logout),
            ),
          ],
        ),
      ),
    );
  }
}
