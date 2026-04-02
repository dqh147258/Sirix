import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_device_list/feature_device_list.dart';
import 'package:feature_remote_view/feature_remote_view.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:infra_api/infra_api.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      AppLogger.configure(
        source: AppLogSource.flutterMobile,
        baseUrl: resolvedApiBaseUrl,
      );
      AppLogger.info(
        '[MEDIA_AUTH_TRACE] mobile app startup useMockBackend=$useMockBackend apiBaseUrl=$resolvedApiBaseUrl',
      );
      _installUnhandledErrorLogging();
      runApp(const ProviderScope(child: MobileApp()));
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

class MobileApp extends StatelessWidget {
  const MobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Freeloom Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkFreeloom(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: const MobileHomePage(),
    );
  }
}

class MobileHomePage extends ConsumerStatefulWidget {
  const MobileHomePage({super.key});

  @override
  ConsumerState<MobileHomePage> createState() => _MobileHomePageState();
}

class _MobileHomePageState extends ConsumerState<MobileHomePage> {
  int _index = 0;
  RemoteSessionSummary? _activeSession;

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authViewModelProvider('mobile'));
    final session = authState.session;
    final palette = context.freeloom;
    final l10n = context.l10n;

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
      _MobileAccountPage(
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
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF0A0D11),
              palette.background,
              const Color(0xFF080B10),
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _DotGridPainter(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            Positioned(
              top: -100,
              right: -80,
              child: _GlowBlob(color: palette.primaryBright.withValues(alpha: 0.08)),
            ),
            Positioned(
              bottom: -120,
              left: -70,
              child: _GlowBlob(color: palette.secondary.withValues(alpha: 0.08)),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _MobileShellTopBar(
                      username: session.username,
                      onOpenAccount: () => setState(() => _index = 3),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                          child: DecoratedBox(
                            decoration: AppTheme.glassDecoration(
                              context,
                              radius: 18,
                              fillColor: const Color(0xE611151A),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                            ),
                            child: pages[_index],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: NavigationBar(
              height: 68,
              backgroundColor: const Color(0xE61B2026),
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.desktop_windows_outlined),
                  selectedIcon: const Icon(Icons.desktop_windows_rounded),
                  label: l10n.nodesNav,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.live_tv_outlined),
                  selectedIcon: const Icon(Icons.live_tv_rounded),
                  label: l10n.monitors,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.terminal_rounded),
                  selectedIcon: const Icon(Icons.terminal),
                  label: l10n.terminal,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.person_outline_rounded),
                  selectedIcon: const Icon(Icons.person_rounded),
                  label: l10n.account,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileShellTopBar extends StatelessWidget {
  const _MobileShellTopBar({
    required this.username,
    required this.onOpenAccount,
  });

  final String username;
  final VoidCallback onOpenAccount;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF12171D).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Icon(Icons.connected_tv_rounded, color: palette.primaryBright, size: 18),
          const SizedBox(width: 10),
          Text(
            'HYPERSYNC PRO',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 24),
          ),
          const Spacer(),
          InkWell(
            onTap: onOpenAccount,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: palette.surfaceRaised,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                child: Text(
                  username.isEmpty ? 'F' : username[0].toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileAccountPage extends StatelessWidget {
  const _MobileAccountPage({
    required this.username,
    required this.onLogout,
  });

  final String username;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(l10n.account, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 30)),
        const SizedBox(height: 8),
        Text(
          l10n.mobileAccountReady,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.textMuted),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: AppTheme.glassDecoration(
            context,
            radius: 18,
            fillColor: palette.surfaceRaised.withValues(alpha: 0.78),
          ),
          child: Column(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: palette.primaryBright.withValues(alpha: 0.15),
                child: Text(
                  username.isEmpty ? 'F' : username[0].toUpperCase(),
                  style: TextStyle(color: palette.primaryBright, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
              Text(username, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                l10n.mobileWorkspaceEntry,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.textMuted),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onLogout,
                  icon: const Icon(Icons.logout_rounded),
                  label: Text(l10n.logout),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({
    required this.color,
  });

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      height: 240,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: color,
            blurRadius: 90,
            spreadRadius: 10,
          ),
        ],
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  const _DotGridPainter({
    required this.color,
  });

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (double x = 10; x < size.width; x += 14) {
      for (double y = 10; y < size.height; y += 14) {
        canvas.drawCircle(Offset(x, y), 0.8, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) => oldDelegate.color != color;
}
