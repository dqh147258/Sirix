import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_desktop_authorize/feature_desktop_authorize.dart';
import 'package:feature_device_list/feature_device_list.dart';
import 'package:feature_remote_view/feature_remote_view.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:infra_api/infra_api.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      final source = switch (defaultTargetPlatform) {
        TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux =>
          AppLogSource.flutterDesktop,
        _ => AppLogSource.flutterMobile,
      };
      AppLogger.configure(source: source, baseUrl: resolvedApiBaseUrl);
      _installUnhandledErrorLogging();
      runApp(const ProviderScope(child: FreeloomShellApp()));
    },
    (error, stackTrace) {
      AppLogger.error('uncaught zone error: $error');
      AppLogger.error('uncaught zone stack: $stackTrace');
    },
  );
}

void _installUnhandledErrorLogging() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLogger.error('flutter framework error: ${details.exceptionAsString()}');
    if (details.stack != null) {
      AppLogger.error('flutter framework stack: ${details.stack}');
    }
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLogger.error('platform error: $error');
    AppLogger.error('platform stack: $stackTrace');
    return true;
  };
}

class FreeloomShellApp extends StatelessWidget {
  const FreeloomShellApp({super.key});

  bool get _useDesktopShell {
    if (kIsWeb) {
      return false;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _useDesktopShell ? 'Freeloom Desktop' : 'Freeloom Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkFreeloom(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: _useDesktopShell ? const _DesktopShellPage() : const _MobileShellPage(),
    );
  }
}

class _DesktopShellPage extends ConsumerStatefulWidget {
  const _DesktopShellPage();

  @override
  ConsumerState<_DesktopShellPage> createState() => _DesktopShellPageState();
}

class _DesktopShellPageState extends ConsumerState<_DesktopShellPage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authViewModelProvider('desktop'));
    final authorizeState = ref.watch(desktopAuthorizeViewModelProvider);
    if (!authState.isAuthenticated) {
      return const AuthPage(clientType: 'desktop');
    }

    final pages = [
      TerminalPage(
        accessToken: authState.session!.accessToken,
        deviceId: authorizeState.registeredDeviceId,
      ),
      DesktopAuthorizePage(authSession: authState.session),
      const AuthPage(clientType: 'desktop'),
    ];

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF090C11), Color(0xFF0D1117), Color(0xFF080B10)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xF012171D),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
                        Text('RemoteTerm', style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(width: 18),
                        for (final item in [(0, context.l10n.terminal), (1, context.l10n.authorize), (2, context.l10n.account)])
                          Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: InkWell(
                              onTap: () => setState(() => _index = item.$1),
                              child: Text(
                                item.$2,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: _index == item.$1 ? context.freeloom.primaryBright : context.freeloom.textMuted,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                          ),
                        const Spacer(),
                        TextButton(
                          onPressed: ref.read(authViewModelProvider('desktop').notifier).logout,
                          child: Text(context.l10n.logout),
                        ),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: pages[_index]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileShellPage extends ConsumerStatefulWidget {
  const _MobileShellPage();

  @override
  ConsumerState<_MobileShellPage> createState() => _MobileShellPageState();
}

class _MobileShellPageState extends ConsumerState<_MobileShellPage> {
  int _index = 0;
  RemoteSessionSummary? _activeSession;

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authViewModelProvider('mobile'));
    final session = authState.session;

    if (session == null) {
      return const AuthPage(clientType: 'mobile');
    }

    final remoteViewState = ref.watch(remoteViewViewModelProvider);
    final fullscreenRemote = _index == 1 &&
        remoteViewState.sessionId != null &&
        remoteViewState.orientationMode == ViewOrientationMode.landscape;

    final pages = [
      DeviceListPage(
        accessToken: session.accessToken,
        onConnectSession: (value) {
          setState(() {
            _activeSession = value;
            _index = 1;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
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
        connectedSession: _activeSession,
      ),
      TerminalPage(
        accessToken: session.accessToken,
        deviceId: _activeSession?.targetDeviceId ?? remoteViewState.deviceId,
        allowCreate: false,
      ),
      _ShellAccountPage(
        username: session.username,
        onLogout: () {
          ref.read(authViewModelProvider('mobile').notifier).logout();
          setState(() {
            _activeSession = null;
            _index = 0;
          });
        },
      ),
    ];

    if (fullscreenRemote) {
      return Scaffold(body: pages[_index]);
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
                  child: pages[_index],
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (value) => setState(() => _index = value),
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
