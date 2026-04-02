import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_desktop_authorize/feature_desktop_authorize.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:infra_api/infra_api.dart';
import 'package:infra_webrtc/infra_webrtc.dart';

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
      title: 'Freeloom Desktop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkFreeloom(),
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
  Widget build(BuildContext context) {
    final authState = ref.watch(authViewModelProvider('desktop'));
    final authorizeState = ref.watch(desktopAuthorizeViewModelProvider);
    final palette = context.freeloom;
    if (!authState.isAuthenticated) {
      return const AuthPage(clientType: 'desktop');
    }

    final pages = [
      _DesktopDashboardPage(session: authState.session!),
      TerminalPage(
        accessToken: authState.session!.accessToken,
        deviceId: authorizeState.registeredDeviceId,
      ),
      DesktopAuthorizePage(authSession: authState.session),
      const AuthPage(clientType: 'desktop'),
    ];

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF0A0C11),
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
              top: -120,
              right: -80,
              child: _GlowBlob(color: palette.secondary.withValues(alpha: 0.08)),
            ),
            Positioned(
              bottom: -180,
              left: -40,
              child: _GlowBlob(color: palette.primaryBright.withValues(alpha: 0.1)),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF10141A).withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: const Color(0xFF6A63FF).withValues(alpha: 0.85), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.36),
                        blurRadius: 40,
                        offset: const Offset(0, 24),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      _DesktopTopBar(
                        selectedIndex: _navigationIndex,
                        username: authState.session!.username,
                        onSelect: (index) => setState(() => _navigationIndex = index),
                        onLogout: () {
                          ref.read(authViewModelProvider('desktop').notifier).logout();
                          setState(() => _navigationIndex = 0);
                        },
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: Row(
                          children: [
                            _DesktopSidebar(
                              selectedIndex: _navigationIndex,
                              onSelected: (index) => setState(() => _navigationIndex = index),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                child: KeyedSubtree(
                                  key: ValueKey(_navigationIndex),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: pages[_navigationIndex],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopTopBar extends StatelessWidget {
  const _DesktopTopBar({
    required this.selectedIndex,
    required this.username,
    required this.onSelect,
    required this.onLogout,
  });

  final int selectedIndex;
  final String username;
  final ValueChanged<int> onSelect;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;
    final items = [
      l10n.dashboardNav,
      l10n.terminalNav,
      l10n.authorizeNav,
    ];

    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text(
              'RemoteTerm',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 24),
            ),
            const SizedBox(width: 24),
            for (var index = 0; index < items.length; index++)
              Padding(
                padding: const EdgeInsets.only(right: 18),
                child: InkWell(
                  onTap: () => onSelect(index),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 160),
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                          color: selectedIndex == index ? const Color(0xFF6E8BFF) : palette.textMuted,
                          fontWeight: selectedIndex == index ? FontWeight.w700 : FontWeight.w500,
                        ),
                    child: Text(items[index]),
                  ),
                ),
              ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: palette.primaryBright.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: palette.primaryBright,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: palette.primaryBright.withValues(alpha: 0.5),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.desktopNodeActive,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.primaryBright,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'JetBrains Mono',
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.notifications_none_rounded, size: 20),
            const SizedBox(width: 10),
            const Icon(Icons.help_outline_rounded, size: 20),
            const SizedBox(width: 10),
            InkWell(
              onTap: onLogout,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: palette.surfaceRaised,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: palette.glassStroke),
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
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;
    final items = [
      (Icons.monitor_rounded, l10n.monitors, 0),
      (Icons.terminal_rounded, l10n.terminal, 1),
      (Icons.lock_outline_rounded, l10n.authorize, 2),
      (Icons.settings_outlined, l10n.settingsLabel, 3),
    ];

    return SizedBox(
      width: 168,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('RemoteTerm Pro', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    l10n.desktopConnectedNodes,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                          fontFamily: 'JetBrains Mono',
                        ),
                  ),
                ],
              ),
            ),
            for (final item in items) ...[
              _DesktopNavItem(
                icon: item.$1,
                label: item.$2,
                selected: selectedIndex == item.$3,
                onTap: () => onSelected(item.$3),
              ),
              const SizedBox(height: 8),
            ],
            const Spacer(),
            const Divider(height: 1),
            const SizedBox(height: 12),
            _FooterNavItem(icon: Icons.support_agent_rounded, label: l10n.supportLabel),
            const SizedBox(height: 6),
            _FooterNavItem(icon: Icons.history_rounded, label: l10n.logsLabel),
          ],
        ),
      ),
    );
  }
}

class _DesktopNavItem extends StatelessWidget {
  const _DesktopNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1B2050) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 17, color: selected ? const Color(0xFF7F99FF) : palette.textMuted),
            const SizedBox(width: 10),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: selected ? palette.textPrimary : palette.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FooterNavItem extends StatelessWidget {
  const _FooterNavItem({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: palette.textMuted),
          const SizedBox(width: 10),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.textMuted),
          ),
        ],
      ),
    );
  }
}

class _DesktopDashboardPage extends ConsumerWidget {
  const _DesktopDashboardPage({
    required this.session,
  });

  final AuthSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authorizeState = ref.watch(desktopAuthorizeViewModelProvider);
    final mediaState = ref.watch(desktopMediaControllerProvider);
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Text(
                                  l10n.primaryDisplayTitle,
                                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                        fontSize: 30,
                                        letterSpacing: -0.6,
                                      ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  authorizeState.registeredDeviceId ?? '192.168.1.104:8080',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: palette.secondary,
                                        fontFamily: 'JetBrains Mono',
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            children: [
                              _DesktopMetric(label: l10n.latencyLabel, value: '14ms'),
                              const SizedBox(width: 18),
                              _DesktopMetric(label: l10n.frameRateLabel, value: '60fps'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            flex: 8,
                            child: Container(
                              margin: const EdgeInsets.only(right: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0E1215),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: Padding(
                                      padding: const EdgeInsets.all(18),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(12),
                                          gradient: RadialGradient(
                                            center: const Alignment(0.1, -0.2),
                                            radius: 0.95,
                                            colors: [
                                              const Color(0xFF182D32),
                                              const Color(0xFF0B1014),
                                              const Color(0xFF070A0E),
                                            ],
                                          ),
                                        ),
                                        child: Stack(
                                          children: [
                                            Positioned.fill(
                                              child: CustomPaint(
                                                painter: _BlueprintPainter(
                                                  lineColor: palette.secondary.withValues(alpha: 0.12),
                                                ),
                                              ),
                                            ),
                                            Center(
                                              child: Container(
                                                width: 220,
                                                height: 260,
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(40),
                                                  gradient: const LinearGradient(
                                                    begin: Alignment.topCenter,
                                                    end: Alignment.bottomCenter,
                                                    colors: [
                                                      Color(0xFF1F3440),
                                                      Color(0xFF0E161B),
                                                    ],
                                                  ),
                                                  border: Border.all(
                                                    color: Colors.white.withValues(alpha: 0.08),
                                                  ),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: palette.secondary.withValues(alpha: 0.18),
                                                      blurRadius: 30,
                                                    ),
                                                  ],
                                                ),
                                                child: Center(
                                                  child: Container(
                                                    width: 82,
                                                    height: 180,
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(18),
                                                      gradient: const LinearGradient(
                                                        begin: Alignment.topCenter,
                                                        end: Alignment.bottomCenter,
                                                        colors: [
                                                          Color(0xFF10202A),
                                                          Color(0xFF090D10),
                                                        ],
                                                      ),
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: palette.secondary.withValues(alpha: 0.16),
                                                          blurRadius: 18,
                                                        ),
                                                      ],
                                                    ),
                                                    child: Center(
                                                      child: Container(
                                                        width: 12,
                                                        height: 132,
                                                        decoration: BoxDecoration(
                                                          borderRadius: BorderRadius.circular(999),
                                                          gradient: LinearGradient(
                                                            begin: Alignment.topCenter,
                                                            end: Alignment.bottomCenter,
                                                            colors: [
                                                              palette.secondary.withValues(alpha: 0.18),
                                                              palette.secondary,
                                                              palette.secondary.withValues(alpha: 0.18),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              right: 16,
                                              top: 16,
                                              child: Container(
                                                width: 10,
                                                height: 10,
                                                decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  borderRadius: BorderRadius.circular(999),
                                                  boxShadow: const [
                                                    BoxShadow(color: Colors.white, blurRadius: 12),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              bottom: 16,
                                              left: 18,
                                              right: 18,
                                              child: ClipRRect(
                                                borderRadius: BorderRadius.circular(999),
                                                child: BackdropFilter(
                                                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black.withValues(alpha: 0.32),
                                                      borderRadius: BorderRadius.circular(999),
                                                      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                                                    ),
                                                    child: Row(
                                                      mainAxisAlignment: MainAxisAlignment.center,
                                                      children: const [
                                                        Icon(Icons.videocam_rounded, size: 18),
                                                        SizedBox(width: 20),
                                                        Icon(Icons.mic_none_rounded, size: 18),
                                                        SizedBox(width: 20),
                                                        Icon(Icons.desktop_windows_rounded, size: 18),
                                                        SizedBox(width: 20),
                                                        Icon(Icons.call_end_rounded, size: 18, color: Color(0xFFFF7F8F)),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: Column(
                              children: [
                                Expanded(
                                  child: _MonitorPreviewCard(
                                    title: 'MONITOR 02',
                                    subtitle: authorizeState.deviceId ?? l10n.awaitingSync,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: _MonitorPreviewCard(
                                    title: 'MONITOR 03',
                                    subtitle: mediaState.sharedScreenId ?? l10n.standbyLabel,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Color(0xFF0D1014)),
              child: TerminalPage(
                accessToken: session.accessToken,
                deviceId: authorizeState.registeredDeviceId,
                showHeader: false,
                compact: true,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopMetric extends StatelessWidget {
  const _DesktopMetric({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: palette.textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: palette.primaryBright,
                fontWeight: FontWeight.w700,
                fontFamily: 'JetBrains Mono',
              ),
        ),
      ],
    );
  }
}

class _MonitorPreviewCard extends StatelessWidget {
  const _MonitorPreviewCard({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1115),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
                child: Center(
                  child: Icon(Icons.desktop_windows_outlined, color: Colors.white.withValues(alpha: 0.22), size: 72),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Center(
            child: Text(
              title,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 12,
            child: Text(
              subtitle,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                    fontFamily: 'JetBrains Mono',
                  ),
            ),
          ),
        ],
      ),
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
      width: 360,
      height: 360,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: color,
            blurRadius: 120,
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
    for (double x = 8; x < size.width; x += 14) {
      for (double y = 8; y < size.height; y += 14) {
        canvas.drawCircle(Offset(x, y), 0.8, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) => oldDelegate.color != color;
}

class _BlueprintPainter extends CustomPainter {
  const _BlueprintPainter({
    required this.lineColor,
  });

  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (double x = 0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BlueprintPainter oldDelegate) =>
      oldDelegate.lineColor != lineColor;
}
