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
    final palette = context.freeloom;
    final l10n = context.l10n;

    if (!authState.initialized || authState.isInitializing) {
      return const _MobileAuthBootstrapScreen();
    }

    if (session == null) {
      return const AuthPage(clientType: 'mobile');
    }

    final remoteViewState = ref.watch(remoteViewViewModelProvider);
    ref.listen<RemoteViewState>(remoteViewViewModelProvider, (previous, next) {
      if ((previous?.sessionId != null || previous?.sessionState != null) &&
          next.sessionId == null &&
          next.sessionState == null &&
          mounted) {
        setState(() {
          _activeSession = null;
          if (_index != 3) {
            _index = 0;
          }
        });
      }
    });

    final hasRemoteWorkspace = _activeSession != null ||
        remoteViewState.sessionId != null ||
        remoteViewState.sessionState != null;
    final fullscreenRemote = (_index == 0 || _index == 1) &&
        remoteViewState.sessionId != null &&
        remoteViewState.orientationMode == ViewOrientationMode.landscape;

    final pages = [
      hasRemoteWorkspace
          ? RemoteViewPage(
              accessToken: session.accessToken,
              connectedSession: _activeSession,
              layout: RemoteViewLayout.workspace,
            )
          : DeviceListPage(
              accessToken: session.accessToken,
              onConnectSession: (value) {
                setState(() {
                  _activeSession = value;
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
        layout: RemoteViewLayout.monitor,
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
      backgroundColor: const Color(0xFF111316),
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter:
                  _DotGridPainter(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          Positioned(
            top: -100,
            right: -80,
            child:
                _GlowBlob(color: palette.primaryBright.withValues(alpha: 0.08)),
          ),
          Positioned(
            bottom: -120,
            left: -70,
            child: _GlowBlob(color: palette.secondary.withValues(alpha: 0.08)),
          ),
          Column(
            children: [
              SafeArea(
                bottom: false,
                child: _MobileShellTopBar(
                  username: session.username,
                  onOpenAccount: () => setState(() => _index = 3),
                ),
              ),
              Expanded(
                child: pages[_index],
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: _MobileBottomNavBar(
        currentIndex: _index,
        onSelect: (value) => setState(() => _index = value),
        destinations: [
          _MobileNavDestination(
            label: l10n.nodesNav,
            icon: Icons.desktop_windows_outlined,
            selectedIcon: Icons.desktop_windows_rounded,
          ),
          _MobileNavDestination(
            label: l10n.monitors,
            icon: Icons.live_tv_outlined,
            selectedIcon: Icons.live_tv_rounded,
          ),
          _MobileNavDestination(
            label: l10n.terminal,
            icon: Icons.terminal_rounded,
            selectedIcon: Icons.terminal,
          ),
          _MobileNavDestination(
            label: l10n.account,
            icon: Icons.person_outline_rounded,
            selectedIcon: Icons.person_rounded,
          ),
        ],
      ),
    );
  }
}

class _MobileAuthBootstrapScreen extends StatelessWidget {
  const _MobileAuthBootstrapScreen();

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Scaffold(
      backgroundColor: const Color(0xFF111316),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: palette.primaryBright,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Restoring mobile session...',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: palette.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileBottomNavBar extends StatelessWidget {
  const _MobileBottomNavBar({
    required this.currentIndex,
    required this.onSelect,
    required this.destinations,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;
  final List<_MobileNavDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xE61E2023),
        border: Border(
            top: BorderSide(
                color: const Color(0xFF3B4B37).withValues(alpha: 0.15))),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 48,
            offset: Offset(0, -24),
          ),
        ],
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 64,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (var index = 0; index < destinations.length; index++)
                    _MobileBottomNavItem(
                      destination: destinations[index],
                      selected: currentIndex == index,
                      activeColor: palette.primaryBright,
                      onTap: () => onSelect(index),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileBottomNavItem extends StatelessWidget {
  const _MobileBottomNavItem({
    required this.destination,
    required this.selected,
    required this.activeColor,
    required this.onTap,
  });

  final _MobileNavDestination destination;
  final bool selected;
  final Color activeColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final inactiveColor = Colors.white.withValues(alpha: 0.44);

    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? destination.selectedIcon : destination.icon,
              size: 26,
              color: selected ? activeColor : inactiveColor,
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 32,
              height: 2,
              decoration: BoxDecoration(
                color: selected ? activeColor : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileNavDestination {
  const _MobileNavDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
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
      height: 64,
      width: double.infinity,
      color: const Color(0xFF111316),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Icon(Icons.terminal_rounded, color: palette.primaryBright, size: 24),
          const SizedBox(width: 12),
          Text(
            'HYPERSYNC PRO',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2.0,
                  color: palette.primaryBright,
                  fontFamily: 'Space Grotesk',
                ),
          ),
          const Spacer(),
          InkWell(
            onTap: onOpenAccount,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                child: Text(
                  username.isEmpty ? 'F' : username[0].toUpperCase(),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14),
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
        Text(l10n.account,
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(fontSize: 30)),
        const SizedBox(height: 8),
        Text(
          l10n.mobileAccountReady,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: palette.textMuted),
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
                  style: TextStyle(
                      color: palette.primaryBright,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
              Text(username, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                l10n.mobileWorkspaceEntry,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: palette.textMuted),
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
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) =>
      oldDelegate.color != color;
}
