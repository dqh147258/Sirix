import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_desktop_authorize/feature_desktop_authorize.dart';
import 'package:feature_settings_ai/feature_settings_ai.dart';
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
      title: 'Sirix',
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
  static const int _globalSettingsSectionIndex = 4;
  static const int _workspaceSettingsSectionIndex = 5;

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
        label: l10n.status,
        title: l10n.runtimeStatusTitle,
        subtitle: l10n.runtimeStatusSubtitle,
        icon: Icons.monitor_heart_rounded,
        child: const StatusPage(showHeader: false),
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
      _DesktopSection(
        label: l10n.globalSettingsTitle,
        title: l10n.globalSettingsTitle,
        subtitle: l10n.globalSettingsSubtitle,
        icon: Icons.tune_rounded,
        child: const AiSettingsPage(scope: AiSettingsScope.global),
      ),
      _DesktopSection(
        label: l10n.workspaceSettingsTitle,
        title: l10n.workspaceSettingsTitle,
        subtitle: l10n.workspaceSettingsSubtitle,
        icon: Icons.folder_special_rounded,
        child: const AiSettingsPage(scope: AiSettingsScope.workspace),
      ),
    ];
    final currentSection =
        sections[_navigationIndex.clamp(0, sections.length - 1)];
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final useCollapsedSidebar = viewportWidth < 1320;
    final sidebarWidth = useCollapsedSidebar ? 84.0 : 240.0;

    return Scaffold(
      backgroundColor:
          palette.surface, // bg-surface (usually slate-900 in dark mode)
      body: Stack(
        children: [
          DesktopAuthorizeBootstrap(authSession: authState.session),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- SIDEBAR / OUTER SHELL CHROME ---
              Container(
                width: sidebarWidth,
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
                      padding: EdgeInsets.fromLTRB(
                        useCollapsedSidebar ? 12 : 20,
                        24,
                        useCollapsedSidebar ? 12 : 20,
                        24,
                      ),
                      child: useCollapsedSidebar
                          ? Center(
                              child: Tooltip(
                                message: 'Sirix',
                                waitDuration: const Duration(milliseconds: 250),
                                child: const SirixBrandMark(
                                  size: 28,
                                  showPlate: true,
                                ),
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const SirixBrandMark(
                                      size: 30,
                                      showPlate: true,
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      'Sirix',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                        fontFamily: 'Space Grotesk',
                                        color: palette.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.symmetric(
                          horizontal: useCollapsedSidebar ? 10 : 12,
                        ),
                        children: sections.asMap().entries.map((entry) {
                          final isActive = _navigationIndex == entry.key;
                          return _DesktopSidebarNavItem(
                            icon: entry.value.icon,
                            label: entry.value.label,
                            active: isActive,
                            collapsed: useCollapsedSidebar,
                            palette: palette,
                            onTap: () {
                              setState(() => _navigationIndex = entry.key);
                            },
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: useCollapsedSidebar ? 10 : 12,
                      ),
                      child: Column(
                        children: [
                          _SidebarFooterItem(
                            icon: Icons.help_outline_rounded,
                            label: l10n.supportLabel,
                            collapsed: useCollapsedSidebar,
                            palette: palette,
                          ),
                          _SidebarFooterItem(
                            icon: Icons.history_rounded,
                            label: l10n.logsLabel,
                            collapsed: useCollapsedSidebar,
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
                child: Column(
                  children: [
                    Container(
                      height: 56,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        color: palette.surface,
                        border: Border(
                          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              // The sidebar is the outer shell anchor now, so
                              // the content header only carries the active
                              // section tab to the right of that shell chrome.
                              _TopNavBarTab(
                                label: currentSection.label,
                                active: true,
                                palette: palette,
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
                              PopupMenuButton<_AccountMenuAction>(
                                onSelected: (action) async {
                                  switch (action) {
                                    case _AccountMenuAction.globalSettings:
                                      setState(() => _navigationIndex = _globalSettingsSectionIndex);
                                      break;
                                    case _AccountMenuAction.workspaceSettings:
                                      setState(() => _navigationIndex = _workspaceSettingsSectionIndex);
                                      break;
                                    case _AccountMenuAction.logout:
                                      await ref.read(authViewModelProvider('desktop').notifier).logout();
                                      break;
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: _AccountMenuAction.globalSettings,
                                    child: Text(l10n.globalSettingsTitle),
                                  ),
                                  PopupMenuItem(
                                    value: _AccountMenuAction.workspaceSettings,
                                    child: Text(l10n.workspaceSettingsTitle),
                                  ),
                                  PopupMenuItem(
                                    value: _AccountMenuAction.logout,
                                    child: Text(l10n.logout),
                                  ),
                                ],
                                child: Container(
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
                                          : l10n.fallbackAvatarInitial,
                                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
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
              context.l10n.checkingDesktopSession,
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

enum _AccountMenuAction {
  globalSettings,
  workspaceSettings,
  logout,
}

class _SidebarFooterItem extends StatelessWidget {
  const _SidebarFooterItem({
    required this.icon,
    required this.label,
    required this.collapsed,
    required this.palette,
  });

  final IconData icon;
  final String label;
  final bool collapsed;
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
          child: Tooltip(
            message: label,
            waitDuration: const Duration(milliseconds: 250),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: collapsed ? 12 : 12,
                vertical: 10,
              ),
              child: collapsed
                  ? Center(
                      child: Icon(
                        icon,
                        size: 16,
                        color: palette.textMuted,
                      ),
                    )
                  : Row(
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
      ),
    );
  }
}

class _DesktopSidebarNavItem extends StatelessWidget {
  const _DesktopSidebarNavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.collapsed,
    required this.palette,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool collapsed;
  final SirixTheme palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Tooltip(
            message: label,
            waitDuration: const Duration(milliseconds: 250),
            child: Container(
              decoration: BoxDecoration(
                color: active ? palette.primary.withValues(alpha: 0.15) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: collapsed ? 12 : 12,
                vertical: 12,
              ),
              child: collapsed
                  ? Center(
                      child: Icon(
                        icon,
                        size: 18,
                        color: active ? palette.primaryBright : palette.textMuted,
                      ),
                    )
                  : Row(
                      children: [
                        Icon(
                          icon,
                          size: 18,
                          color: active ? palette.primaryBright : palette.textMuted,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          label,
                          style: TextStyle(
                            color: active ? palette.primaryBright : palette.textMuted,
                            fontSize: 13,
                            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                          ),
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

class _DesktopDashboardPage extends ConsumerStatefulWidget {
  const _DesktopDashboardPage({required this.session});

  final AuthSession session;

  @override
  ConsumerState<_DesktopDashboardPage> createState() => _DesktopDashboardPageState();
}

class _DesktopDashboardPageState extends ConsumerState<_DesktopDashboardPage> {
  static const double _resizeHandleHeight = 18;
  static const double _maxSummaryHeight = 320;
  static const double _minTerminalHeight = 280;
  static const double _maxTerminalHeight = 360;
  static const double _defaultSummaryViewportFraction = 0.36;
  static const double _maxSummaryViewportFraction = 0.56;
  static const double _summaryHeightBreathingRoom = 16;

  bool _terminalExpanded = false;
  double? _summaryHeight;

  @override
  Widget build(BuildContext context) {
    final authorizeState = ref.watch(desktopAuthorizeViewModelProvider);
    final mediaState = ref.watch(desktopMediaControllerProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final requiredSummaryHeight = _requiredSummaryHeightForWidth(
            constraints.maxWidth,
          );
          final requiredTerminalHeight = _requiredTerminalHeightForViewport(
            constraints.maxHeight,
          );
          final maxAllowedSummaryHeight = clampDouble(
            constraints.maxHeight - requiredTerminalHeight - _resizeHandleHeight,
            requiredSummaryHeight,
            math.min(
              _maxSummaryHeight,
              constraints.maxHeight * _maxSummaryViewportFraction,
            ),
          );
          final preferredSummaryHeight = clampDouble(
            math.max(
              requiredSummaryHeight + _summaryHeightBreathingRoom,
              constraints.maxHeight * _defaultSummaryViewportFraction,
            ),
            requiredSummaryHeight,
            maxAllowedSummaryHeight,
          );
          final currentSummaryHeight = clampDouble(
            _summaryHeight ?? preferredSummaryHeight,
            requiredSummaryHeight,
            maxAllowedSummaryHeight,
          );

          if (_terminalExpanded) {
            return _DashboardTerminalPanel(
              accessToken: widget.session.accessToken,
              deviceId: authorizeState.registeredDeviceId,
              expanded: true,
              onToggleExpanded: _toggleTerminalExpanded,
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: currentSummaryHeight,
                child: _DashboardSummaryPanel(
                  session: widget.session,
                  connected: authorizeState.connected,
                  connectedScreenId: mediaState.sharedScreenId,
                  frameRate: mediaState.captureFrameRate,
                  latencyLabel: authorizeState.connected
                      ? '${authorizeState.localLatencyMs ?? 14} ms'
                      : '--',
                ),
              ),
              _DashboardResizeHandle(
                onDragUpdate: (delta) {
                  setState(() {
                    _summaryHeight = clampDouble(
                      currentSummaryHeight + delta,
                      requiredSummaryHeight,
                      maxAllowedSummaryHeight,
                    );
                  });
                },
              ),
              Expanded(
                child: _DashboardTerminalPanel(
                  accessToken: widget.session.accessToken,
                  deviceId: authorizeState.registeredDeviceId,
                  expanded: false,
                  onToggleExpanded: _toggleTerminalExpanded,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _toggleTerminalExpanded() {
    // Expanding the terminal only changes the surrounding dashboard layout.
    // The embedded TerminalPage remains mounted so live PTY/tabs survive the
    // mode switch instead of resetting when the user enters fullscreen.
    setState(() => _terminalExpanded = !_terminalExpanded);
  }

  double _requiredSummaryHeightForWidth(double width) {
    // Keep the minimum summary height derived from the *actual* dashboard card
    // geometry instead of coarse breakpoints. This gives the first render more
    // headroom and prevents the summary cards from colliding with the terminal
    // when window width or localization nudges the cards onto extra wrap rows.
    const metricWidths = [188.0, 150.0, 128.0, 128.0];
    const metricSpacing = 12.0;
    const horizontalPadding = 36.0;
    const verticalPadding = 34.0;
    const headerHeight = 60.0;
    const headerToMetricsGap = 14.0;
    const metricRowHeight = 90.0;

    final availableWidth = math.max(0.0, width - horizontalPadding);
    var rows = 1;
    var occupiedWidth = 0.0;

    for (final metricWidth in metricWidths) {
      final nextWidth = occupiedWidth == 0
          ? metricWidth
          : occupiedWidth + metricSpacing + metricWidth;
      if (nextWidth > availableWidth && occupiedWidth > 0) {
        rows += 1;
        occupiedWidth = metricWidth;
      } else {
        occupiedWidth = nextWidth;
      }
    }

    return verticalPadding +
        headerHeight +
        headerToMetricsGap +
        (rows * metricRowHeight) +
        ((rows - 1) * metricSpacing);
  }

  double _requiredTerminalHeightForViewport(double height) {
    // The embedded terminal needs a slightly taller floor than the generic
    // design mock once real tabs, close buttons, and tool actions are mounted.
    // Clamp the resize range against that floor so dragging cannot push the UI
    // back into the overlap state the user reported.
    return clampDouble(
      height * 0.42,
      _minTerminalHeight,
      _maxTerminalHeight,
    );
  }
}

class _DashboardSummaryPanel extends StatefulWidget {
  const _DashboardSummaryPanel({
    required this.session,
    required this.connected,
    required this.connectedScreenId,
    required this.frameRate,
    required this.latencyLabel,
  });

  final AuthSession session;
  final bool connected;
  final String? connectedScreenId;
  final int? frameRate;
  final String latencyLabel;

  @override
  State<_DashboardSummaryPanel> createState() => _DashboardSummaryPanelState();
}

class _DashboardSummaryPanelState extends State<_DashboardSummaryPanel> {
  bool _showLatencyDetail = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;
    final username = widget.session.username.trim().isEmpty ? 'sys_admin' : widget.session.username;
    final connectedScreen = (widget.connectedScreenId == null || widget.connectedScreenId!.trim().isEmpty)
        ? l10n.dashboardNoScreenConnected
        : l10n.dashboardConnectedScreen(widget.connectedScreenId!);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              // Keep the summary resilient even if translated labels or future
              // metric additions briefly outgrow the current drag height. The
              // primary protection is the height clamp above; this scroll view
              // is the final guardrail that avoids render-overflow artifacts.
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.dashboardSummaryTitle,
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              connectedScreen,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: palette.secondary,
                                    fontFamily: 'JetBrains Mono',
                                  ),
                            ),
                          ],
                        ),
                      ),
                      _SummaryStatusPill(
                        label: widget.connected
                            ? l10n.connected.toUpperCase()
                            : l10n.disconnected.toUpperCase(),
                        active: widget.connected,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryMetricCard(
                        width: 188,
                        label: l10n.dashboardLoginStatusLabel,
                        value: l10n.dashboardSignedInAs(username),
                        accent: palette.primaryBright,
                      ),
                      _SummaryMetricCard(
                        width: 150,
                        label: l10n.dashboardConnectionStatusLabel,
                        value: widget.connected ? 'Stable' : 'Offline',
                        accent: widget.connected ? palette.primaryBright : palette.textMuted,
                      ),
                      _SummaryMetricCard(
                        width: 128,
                        label: l10n.dashboardRenderRateLabel,
                        value: widget.frameRate == null ? '--' : '${widget.frameRate} fps',
                        accent: palette.secondary,
                      ),
                      MouseRegion(
                        onEnter: (_) => setState(() => _showLatencyDetail = true),
                        onExit: (_) => setState(() => _showLatencyDetail = false),
                        child: _SummaryMetricCard(
                          width: 128,
                          label: l10n.latencyLabel,
                          value: widget.latencyLabel,
                          accent: palette.secondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_showLatencyDetail)
            Positioned(
              top: 18,
              right: 18,
              child: IgnorePointer(
                child: _LatencyHoverCard(
                  title: l10n.dashboardHoverLatencyTitle,
                  body: l10n.dashboardHoverLatencyBody,
                  value: widget.latencyLabel,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryStatusPill extends StatelessWidget {
  const _SummaryStatusPill({
    required this.label,
    required this.active,
  });

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final accent = active ? palette.primaryBright : palette.textMuted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: active ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.4),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: active ? palette.primaryBright : palette.textSecondary,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _SummaryMetricCard extends StatelessWidget {
  const _SummaryMetricCard({
    required this.width,
    required this.label,
    required this.value,
    required this.accent,
  });

  final double width;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.surfaceRaised.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                  fontFamily: 'JetBrains Mono',
                ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Container(
            width: 28,
            height: 2,
            color: accent.withValues(alpha: 0.85),
          ),
        ],
      ),
    );
  }
}

class _LatencyHoverCard extends StatelessWidget {
  const _LatencyHoverCard({
    required this.title,
    required this.body,
    required this.value,
  });

  final String title;
  final String body;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surfaceRaised.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.glassStroke),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: palette.secondary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textSecondary,
                      height: 1.45,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardResizeHandle extends StatelessWidget {
  const _DashboardResizeHandle({
    required this.onDragUpdate,
  });

  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => onDragUpdate(details.delta.dy),
        child: SizedBox(
          height: _DesktopDashboardPageState._resizeHandleHeight,
          child: Center(
            child: Tooltip(
              message: l10n.dashboardResizeHint,
              child: Container(
                width: 72,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.glassStroke,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardTerminalPanel extends StatelessWidget {
  const _DashboardTerminalPanel({
    required this.accessToken,
    required this.deviceId,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final String accessToken;
  final String? deviceId;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: TerminalPage(
          accessToken: accessToken,
          deviceId: deviceId,
          showHeader: false,
          compact: true,
          fullBleed: true,
          trailingTabActions: [
            TerminalToolbarAction(
              icon: expanded ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              tooltip: expanded ? context.l10n.terminalRestoreTooltip : context.l10n.terminalExpandTooltip,
              onPressed: onToggleExpanded,
            ),
          ],
        ),
      ),
    );
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
                            session.username.isEmpty
                                ? l10n.fallbackAvatarInitial
                                : session.username[0].toUpperCase(),
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
                    title: l10n.authModeLabel,
                    value: l10n.authModeValue,
                    hint: l10n.desktopFooterStatus,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _InfoBlock(
                    title: l10n.sessionRoleLabel,
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
