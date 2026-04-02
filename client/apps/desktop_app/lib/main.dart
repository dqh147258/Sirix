import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_desktop_authorize/feature_desktop_authorize.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:infra_api/infra_api.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      AppLogger.configure(
        source: AppLogSource.flutterDesktop,
        baseUrl: resolvedApiBaseUrl,
      );
      AppLogger.info(
        '[MEDIA_AUTH_TRACE] desktop app startup useMockBackend=$useMockBackend apiBaseUrl=$resolvedApiBaseUrl',
      );
      _installUnhandledErrorLogging();
      runApp(const ProviderScope(child: DesktopApp()));
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

class DesktopApp extends StatelessWidget {
  const DesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sirix Desktop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkSirix(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: const DesktopHomePage(),
    );
  }
}

class DesktopHomePage extends ConsumerStatefulWidget {
  const DesktopHomePage({super.key});

  @override
  ConsumerState<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _DesktopHomePageState extends ConsumerState<DesktopHomePage> {
  int _navigationIndex = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      return ref.read(authViewModelProvider('desktop').notifier).initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authViewModelProvider('desktop'));
    final authorizeState = ref.watch(desktopAuthorizeViewModelProvider);
    final palette = context.sirix;
    final l10n = context.l10n;
    if (!authState.initialized || authState.isInitializing) {
      return const _DesktopAuthBootstrapScreen();
    }
    if (!authState.isAuthenticated) {
      return const AuthPage(clientType: 'desktop');
    }

    final sections = [
      _DesktopSection(
        label: l10n.dashboardNav,
        title: l10n.consolePageTitle,
        subtitle: l10n.desktopConsoleSubtitle,
        icon: Icons.space_dashboard_rounded,
        child: _DesktopDashboardPage(session: authState.session!),
      ),
      _DesktopSection(
        label: l10n.terminalNav,
        title: l10n.terminalPageTitle,
        subtitle: l10n.terminalCapabilityHint,
        icon: Icons.terminal_rounded,
        child: TerminalPage(
          accessToken: authState.session!.accessToken,
          deviceId: authorizeState.registeredDeviceId,
          showHeader: false,
        ),
      ),
      _DesktopSection(
        label: l10n.authorizeNav,
        title: l10n.authorizePageTitle,
        subtitle: l10n.desktopAuthorizeIntro,
        icon: Icons.lock_outline_rounded,
        child: DesktopAuthorizePage(authSession: authState.session),
      ),
      _DesktopSection(
        label: l10n.account,
        title: l10n.accountPageTitle,
        subtitle: l10n.desktopAccountReady,
        icon: Icons.account_circle_outlined,
        child: _DesktopAccountPage(session: authState.session!),
      ),
    ];
    final currentSection =
        sections[_navigationIndex.clamp(0, sections.length - 1)];

    return Scaffold(
      backgroundColor:
          palette.surface, // bg-surface (usually slate-900 in dark mode)
      body: Stack(
        children: [
          Column(
            children: [
              DesktopAuthorizeBootstrap(authSession: authState.session),
              // TopNavBar
              Container(
                height: 56, // h-14
                padding: const EdgeInsets.symmetric(horizontal: 24), // px-6
                decoration: BoxDecoration(
                  color: palette.surface, // bg-slate-900
                  border: Border(
                    bottom: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text(
                          'RemoteTerm',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(width: 32), // gap-8
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _TopNavBarTab(label: 'Dashboard', active: true, palette: palette),
                            _TopNavBarTab(label: 'Sessions', active: false, palette: palette),
                            _TopNavBarTab(label: 'Network', active: false, palette: palette),
                          ],
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: palette.surfaceRaised,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: authorizeState.registeredDeviceId != null
                                      ? palette.primaryBright
                                      : palette.textMuted,
                                  shape: BoxShape.circle,
                                  boxShadow: authorizeState.registeredDeviceId != null
                                      ? [
                                          BoxShadow(
                                            color: palette.primaryBright.withValues(alpha: 0.6),
                                            blurRadius: 8,
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                (authorizeState.registeredDeviceId ?? l10n.desktopNodeActive)
                                    .toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'Space Grotesk',
                                  color: palette.primary,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Icon(Icons.notifications_none_rounded, color: palette.textMuted, size: 20),
                        const SizedBox(width: 12),
                        Icon(Icons.help_outline_rounded, color: palette.textMuted, size: 20),
                        const SizedBox(width: 12),
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                            color: palette.surfaceMuted,
                          ),
                          child: Center(
                            child: Text(
                              authState.session!.username.isNotEmpty
                                  ? authState.session!.username[0].toUpperCase()
                                  : 'O',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Main Body (Content)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // --- SIDEBAR ---
                    Container(
                      width: 240,
                      decoration: BoxDecoration(
                        color: const Color(
                            0xFF0C0E11), // surface-container-lowest equivalent
                        border: Border(
                          right: BorderSide(
                            color: Colors.white.withValues(alpha: 0.05),
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'RemoteTerm Pro',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                    fontFamily: 'Space Grotesk',
                                    color: palette.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'CONNECTED: ${authorizeState.pendingRequests.length} NODES',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: palette.textMuted,
                                    fontFamily: 'Space Grotesk',
                                    letterSpacing: 1.2,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              children: sections.asMap().entries.map((entry) {
                                final isActive = _navigationIndex == entry.key;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: () {
                                        setState(() => _navigationIndex = entry.key);
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: isActive
                                              ? palette.primary.withValues(alpha: 0.15)
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 12),
                                        child: Row(
                                          children: [
                                            Icon(
                                              entry.value.icon,
                                              size: 18,
                                              color: isActive
                                                  ? palette.primaryBright
                                                  : palette.textMuted,
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              entry.value.label,
                                              style: TextStyle(
                                                color: isActive
                                                    ? palette.primaryBright
                                                    : palette.textMuted,
                                                fontSize: 13,
                                                fontWeight:
                                                    isActive ? FontWeight.w600 : FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Column(
                              children: [
                                _SidebarFooterItem(
                                  icon: Icons.help_outline_rounded,
                                  label: 'Support',
                                  palette: palette,
                                ),
                                _SidebarFooterItem(
                                  icon: Icons.history_rounded,
                                  label: 'Logs',
                                  palette: palette,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                    // --- CONTENT AREA ---
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(_navigationIndex),
                          child: currentSection.child,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const DesktopAuthorizeRequestOverlay(),
        ],
      ),
    );
  }
}

class _DesktopAuthBootstrapScreen extends StatelessWidget {
  const _DesktopAuthBootstrapScreen();

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Scaffold(
      backgroundColor: palette.surface,
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
              'Checking desktop session...',
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

class _DesktopSection {
  const _DesktopSection({
    required this.label,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String label;
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
}

class _SidebarFooterItem extends StatelessWidget {
  const _SidebarFooterItem({
    required this.icon,
    required this.label,
    required this.palette,
  });

  final IconData icon;
  final String label;
  final SirixTheme palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {},
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: palette.textMuted,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopNavBarTab extends StatelessWidget {
  const _TopNavBarTab(
      {required this.label, required this.active, required this.palette});
  final String label;
  final bool active;
  final SirixTheme palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: active
            ? Border(bottom: BorderSide(color: palette.primaryBright, width: 2))
            : null,
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            color: active ? palette.primaryBright : palette.textMuted,
          ),
        ),
      ),
    );
  }
}

class _DesktopDashboardPage extends ConsumerWidget {
  const _DesktopDashboardPage({required this.session});
  final AuthSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authorizeState = ref.watch(desktopAuthorizeViewModelProvider);
    final palette = context.sirix;
    return Column(children: [
      // --- PRIMARY DISPLAY ---
      Expanded(
          flex: 1,
          child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text('PRIMARY DISPLAY',
                                    style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Space Grotesk',
                                        color: Colors.white,
                                        letterSpacing: -0.5)),
                                const SizedBox(width: 12),
                                Text('192.168.1.104:8080',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'JetBrains Mono',
                                        color: palette.secondary
                                            .withValues(alpha: 0.7))),
                              ]),
                          Row(children: [
                            Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('LATENCY',
                                      style: TextStyle(
                                          fontSize: 9,
                                          color: palette.textMuted,
                                          letterSpacing: 1.2)),
                                  Text('14ms',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontFamily: 'JetBrains Mono',
                                          color: palette.primaryBright)),
                                ]),
                            Container(
                                width: 1,
                                height: 24,
                                color: Colors.white.withValues(alpha: 0.1),
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 12)),
                            Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('FRAMERATE',
                                      style: TextStyle(
                                          fontSize: 9,
                                          color: palette.textMuted,
                                          letterSpacing: 1.2)),
                                  Text('60fps',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontFamily: 'JetBrains Mono',
                                          color: palette.primaryBright)),
                                ]),
                          ])
                        ]),
                    const SizedBox(height: 16),
                    Expanded(
                        child: Row(children: [
                      // Main Monitor
                      Expanded(
                          flex: 2,
                          child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E2023),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color:
                                        Colors.white.withValues(alpha: 0.05)),
                              ),
                              child: Stack(children: [
                                Center(
                                    child: Icon(Icons.monitor,
                                        size: 64,
                                        color: palette.textMuted
                                            .withValues(alpha: 0.1))),
                                Positioned(
                                    top: 16,
                                    right: 16,
                                    child: Container(
                                        width: 12,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          color: palette.secondary,
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                                color: palette.secondary,
                                                blurRadius: 12)
                                          ],
                                        )))
                              ]))),
                      const SizedBox(width: 16),
                      // Sub Monitors
                      Expanded(
                          flex: 1,
                          child: Column(children: [
                            Expanded(
                                child: Container(
                                    decoration: BoxDecoration(
                                        color: const Color(0xFF1A1C1F),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha: 0.05))),
                                    child: Center(
                                        child: Text('MONITOR 02',
                                            style: TextStyle(
                                                fontSize: 10,
                                                fontFamily: 'Space Grotesk',
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                                letterSpacing: 2))))),
                            const SizedBox(height: 16),
                            Expanded(
                                child: Container(
                                    decoration: BoxDecoration(
                                        color: const Color(0xFF1A1C1F),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha: 0.05))),
                                    child: Center(
                                        child: Text('MONITOR 03',
                                            style: TextStyle(
                                                fontSize: 10,
                                                fontFamily: 'Space Grotesk',
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                                letterSpacing: 2))))),
                          ]))
                    ]))
                  ]))),

      // --- TERMINAL AREA ---
      Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TerminalPage(
              accessToken: session.accessToken,
              deviceId: authorizeState.registeredDeviceId,
              showHeader: false,
              compact: true,
            ),
          ))
    ]);
  }
}

class _DesktopAccountPage extends StatelessWidget {
  const _DesktopAccountPage({
    required this.session,
  });

  final AuthSession session;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: palette.surface.withValues(alpha: 0.74),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: palette.primaryBright.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Center(
                          child: Text(
                            session.username.isEmpty ? 'F' : session.username[0].toUpperCase(),
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 28),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.currentAccount,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                              fontFamily: 'JetBrains Mono',
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        session.username,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 40),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        l10n.desktopAccountReady,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: palette.textSecondary,
                              height: 1.6,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            flex: 4,
            child: Column(
              children: [
                Expanded(
                  child: _InfoBlock(
                    title: 'AUTH MODE',
                    value: 'AES-256-GCM',
                    hint: l10n.desktopFooterStatus,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _InfoBlock(
                    title: 'SESSION ROLE',
                    value: l10n.desktopOperator,
                    hint: l10n.secureWorkspaceEntry,
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

class _InfoBlock extends StatelessWidget {
  const _InfoBlock({
    required this.title,
    required this.value,
    required this.hint,
  });

  final String title;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                  fontFamily: 'JetBrains Mono',
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
          ),
          const SizedBox(height: 14),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 28),
          ),
          const SizedBox(height: 12),
          Text(
            hint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textSecondary,
                  height: 1.5,
                ),
          ),
        ],
      ),
    );
  }
}
