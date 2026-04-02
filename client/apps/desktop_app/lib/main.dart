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
    final l10n = context.l10n;
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
    final currentSection = sections[_navigationIndex.clamp(0, sections.length - 1)];

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF081014),
              palette.background,
              const Color(0xFF05080B),
            ],
          ),
        ),
        child: Stack(
          children: [
            DesktopAuthorizeBootstrap(authSession: authState.session),
            Positioned.fill(
              child: CustomPaint(
                painter: _DotGridPainter(color: Colors.white.withValues(alpha: 0.05)),
              ),
            ),
            Positioned(
              top: -120,
              left: -80,
              child: _GlowBlob(color: palette.primaryBright.withValues(alpha: 0.08)),
            ),
            Positioned(
              right: -120,
              bottom: -180,
              child: _GlowBlob(color: palette.secondary.withValues(alpha: 0.08)),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xD9111519),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 42,
                            offset: const Offset(0, 26),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          _DesktopSidebar(
                            sections: sections,
                            selectedIndex: _navigationIndex,
                            username: authState.session!.username,
                            deviceId: authorizeState.registeredDeviceId,
                            onSelected: (index) => setState(() => _navigationIndex = index),
                            onLogout: () {
                              ref.read(authViewModelProvider('desktop').notifier).logout();
                              setState(() => _navigationIndex = 0);
                            },
                          ),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: Colors.white.withValues(alpha: 0.06),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _DesktopContentHeader(
                                    section: currentSection,
                                    username: authState.session!.username,
                                    deviceId: authorizeState.registeredDeviceId,
                                  ),
                                  const SizedBox(height: 18),
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(28),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: [
                                              const Color(0xCC141A1F),
                                              palette.surface.withValues(alpha: 0.86),
                                            ],
                                          ),
                                          borderRadius: BorderRadius.circular(28),
                                          border: Border.all(
                                            color: Colors.white.withValues(alpha: 0.06),
                                          ),
                                        ),
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
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.sections,
    required this.selectedIndex,
    required this.username,
    required this.deviceId,
    required this.onSelected,
    required this.onLogout,
  });

  final List<_DesktopSection> sections;
  final int selectedIndex;
  final String username;
  final String? deviceId;
  final ValueChanged<int> onSelected;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return SizedBox(
      width: 264,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: palette.surface.withValues(alpha: 0.64),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          palette.primaryBright.withValues(alpha: 0.22),
                          palette.primary.withValues(alpha: 0.08),
                        ],
                      ),
                      border: Border.all(color: palette.primaryBright.withValues(alpha: 0.24)),
                    ),
                    child: Icon(
                      Icons.terminal_rounded,
                      color: palette.primaryBright,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'RemoteTerm',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontSize: 28,
                          letterSpacing: -0.8,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.secureWorkspaceEntry,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                          fontFamily: 'JetBrains Mono',
                          letterSpacing: 1.1,
                        ),
                  ),
                  const SizedBox(height: 16),
                  _SidebarTag(
                    icon: Icons.radio_button_checked_rounded,
                    text: deviceId ?? l10n.desktopNodeActive,
                    active: deviceId != null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.controlConsole.toUpperCase(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  ),
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < sections.length; index++) ...[
              _DesktopSidebarItem(
                icon: sections[index].icon,
                label: sections[index].label,
                subtitle: index == 0
                    ? l10n.desktopConnectedNodes
                    : index == 1
                        ? l10n.terminalWorkspace
                        : index == 2
                            ? l10n.pendingRequests
                            : l10n.currentAccount,
                selected: index == selectedIndex,
                onTap: () => onSelected(index),
              ),
              const SizedBox(height: 10),
            ],
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.desktopOperator.toUpperCase(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                          fontFamily: 'JetBrains Mono',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    username,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 22),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.desktopFooterStatus,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                          height: 1.5,
                        ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onLogout,
                      style: FilledButton.styleFrom(
                        backgroundColor: palette.primaryBright.withValues(alpha: 0.14),
                        foregroundColor: palette.textPrimary,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: Text(l10n.logout),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopSidebarItem extends StatelessWidget {
  const _DesktopSidebarItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    palette.primaryBright.withValues(alpha: 0.16),
                    palette.secondary.withValues(alpha: 0.08),
                  ],
                )
              : null,
          border: Border.all(
            color: selected
                ? palette.primaryBright.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.04),
          ),
          color: selected ? null : palette.surface.withValues(alpha: 0.36),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: selected
                    ? Colors.black.withValues(alpha: 0.18)
                    : palette.surfaceRaised.withValues(alpha: 0.52),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                size: 20,
                color: selected ? palette.primaryBright : palette.textSecondary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                          fontSize: 11,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarTag extends StatelessWidget {
  const _SidebarTag({
    required this.icon,
    required this.text,
    required this.active,
  });

  final IconData icon;
  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active
              ? palette.primaryBright.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: active ? palette.primaryBright : palette.textMuted,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: active ? palette.primaryBright : palette.textMuted,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopContentHeader extends StatelessWidget {
  const _DesktopContentHeader({
    required this.section,
    required this.username,
    required this.deviceId,
  });

  final _DesktopSection section;
  final String username;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                section.title,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontSize: 34,
                      letterSpacing: -1.0,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                section.subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: palette.textSecondary,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _HeaderPill(
              icon: Icons.memory_rounded,
              label: deviceId ?? l10n.awaitingSync,
              active: deviceId != null,
            ),
            _HeaderPill(
              icon: Icons.shield_outlined,
              label: l10n.desktopFooterStatus,
              active: true,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: palette.surface.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: palette.primaryBright.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Center(
                      child: Text(
                        username.isEmpty ? 'F' : username[0].toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    username,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _HeaderPill extends StatelessWidget {
  const _HeaderPill({
    required this.icon,
    required this.label,
    required this.active,
  });

  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active
              ? palette.primaryBright.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: active ? palette.primaryBright : palette.textMuted),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: active ? palette.textPrimary : palette.textMuted,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w700,
                  ),
            ),
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
    final displayId = authorizeState.registeredDeviceId ?? authorizeState.deviceId ?? 'desktop-node';

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              _DashboardStatusCard(
                label: l10n.localWs,
                value: authorizeState.connected ? l10n.connected : l10n.disconnected,
                hint: authorizeState.localWsPort == null
                    ? 'WS WAITING'
                    : 'PORT ${authorizeState.localWsPort}',
                active: authorizeState.connected,
              ),
              _DashboardStatusCard(
                label: l10n.sharingState,
                value: mediaState.sharing ? l10n.sharing : l10n.idle,
                hint: mediaState.sharedScreenId ?? l10n.awaitingSync,
                active: mediaState.sharing,
              ),
              _DashboardStatusCard(
                label: l10n.pendingRequests,
                value: '${authorizeState.pendingRequests.length}',
                hint: authorizeState.pendingRequests.isEmpty ? 'QUEUE CLEAR' : 'ACTION REQUIRED',
                active: authorizeState.pendingRequests.isNotEmpty,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 8,
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0A0E12),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(18),
                                      gradient: RadialGradient(
                                        center: const Alignment(0.12, -0.18),
                                        radius: 1.02,
                                        colors: [
                                          palette.surfaceRaised,
                                          const Color(0xFF0A0D10),
                                          const Color(0xFF06080A),
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
                                        Positioned(
                                          top: 18,
                                          left: 18,
                                          child: _SidebarTag(
                                            icon: Icons.desktop_windows_rounded,
                                            text: displayId,
                                            active: true,
                                          ),
                                        ),
                                        Center(
                                          child: Container(
                                            width: 260,
                                            height: 300,
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(42),
                                              gradient: const LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Color(0xFF1A2A30),
                                                  Color(0xFF0B1216),
                                                ],
                                              ),
                                              border: Border.all(
                                                color: Colors.white.withValues(alpha: 0.08),
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: palette.secondary.withValues(alpha: 0.16),
                                                  blurRadius: 26,
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child: Container(
                                                width: 92,
                                                height: 196,
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(24),
                                                  gradient: const LinearGradient(
                                                    begin: Alignment.topCenter,
                                                    end: Alignment.bottomCenter,
                                                    colors: [
                                                      Color(0xFF0E1D25),
                                                      Color(0xFF080C10),
                                                    ],
                                                  ),
                                                ),
                                                child: Center(
                                                  child: Container(
                                                    width: 14,
                                                    height: 146,
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(999),
                                                      gradient: LinearGradient(
                                                        begin: Alignment.topCenter,
                                                        end: Alignment.bottomCenter,
                                                        colors: [
                                                          palette.secondary.withValues(alpha: 0.1),
                                                          palette.secondary,
                                                          palette.secondary.withValues(alpha: 0.1),
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
                                          right: 18,
                                          top: 18,
                                          child: _DashboardMetricChip(
                                            label: l10n.frameRateLabel,
                                            value: mediaState.sharing ? '60 FPS' : '--',
                                          ),
                                        ),
                                        Positioned(
                                          right: 18,
                                          top: 82,
                                          child: _DashboardMetricChip(
                                            label: l10n.latencyLabel,
                                            value: authorizeState.connected ? '14 MS' : '--',
                                          ),
                                        ),
                                        Positioned(
                                          bottom: 18,
                                          left: 18,
                                          right: 18,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(999),
                                            child: BackdropFilter(
                                              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 18,
                                                  vertical: 12,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withValues(alpha: 0.32),
                                                  borderRadius: BorderRadius.circular(999),
                                                  border: Border.all(
                                                    color: Colors.white.withValues(alpha: 0.08),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    _ConsoleActionIcon(
                                                      icon: Icons.videocam_rounded,
                                                      active: mediaState.sharing,
                                                    ),
                                                    const SizedBox(width: 20),
                                                    const _ConsoleActionIcon(
                                                      icon: Icons.mic_none_rounded,
                                                    ),
                                                    const SizedBox(width: 20),
                                                    const _ConsoleActionIcon(
                                                      icon: Icons.desktop_windows_rounded,
                                                    ),
                                                    const SizedBox(width: 20),
                                                    _ConsoleActionIcon(
                                                      icon: Icons.call_end_rounded,
                                                      color: palette.error,
                                                    ),
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
                      const SizedBox(height: 16),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0A0D10),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                          ),
                          child: TerminalPage(
                            accessToken: session.accessToken,
                            deviceId: authorizeState.registeredDeviceId,
                            showHeader: false,
                            compact: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
                  child: Column(
                    children: [
                      Expanded(
                        child: _MonitorPreviewCard(
                          title: 'DISPLAY A',
                          subtitle: displayId,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: _MonitorPreviewCard(
                          title: 'DISPLAY B',
                          subtitle: mediaState.sharedScreenId ?? l10n.standbyLabel,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.currentAccount.toUpperCase(),
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: palette.textMuted,
                                      fontFamily: 'JetBrains Mono',
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.2,
                                    ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                session.username,
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 26),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                l10n.desktopAccountReady,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: palette.textSecondary,
                                      height: 1.5,
                                    ),
                              ),
                              const Spacer(),
                              _SidebarTag(
                                icon: Icons.verified_user_outlined,
                                text: l10n.desktopFooterStatus,
                                active: true,
                              ),
                            ],
                          ),
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
    );
  }
}

class _DashboardStatusCard extends StatelessWidget {
  const _DashboardStatusCard({
    required this.label,
    required this.value,
    required this.hint,
    required this.active,
  });

  final String label;
  final String value;
  final String hint;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return SizedBox(
      width: 260,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? palette.primaryBright.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
            ),
            const SizedBox(height: 14),
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 24),
            ),
            const SizedBox(height: 8),
            Text(
              hint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: active ? palette.primaryBright : palette.textMuted,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardMetricChip extends StatelessWidget {
  const _DashboardMetricChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Container(
      width: 118,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                  fontSize: 10,
                  fontFamily: 'JetBrains Mono',
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.primaryBright,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrains Mono',
                ),
          ),
        ],
      ),
    );
  }
}

class _ConsoleActionIcon extends StatelessWidget {
  const _ConsoleActionIcon({
    required this.icon,
    this.color,
    this.active = false,
  });

  final IconData icon;
  final Color? color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final foreground = color ?? (active ? palette.primaryBright : palette.textPrimary);

    return Icon(icon, size: 18, color: foreground);
  }
}

class _DesktopAccountPage extends StatelessWidget {
  const _DesktopAccountPage({
    required this.session,
  });

  final AuthSession session;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
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
    final palette = context.freeloom;

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
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
                child: Center(
                  child: Icon(
                    Icons.desktop_windows_outlined,
                    color: Colors.white.withValues(alpha: 0.22),
                    size: 76,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(22),
              ),
            ),
          ),
          Center(
            child: Text(
              title,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    fontFamily: 'JetBrains Mono',
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
