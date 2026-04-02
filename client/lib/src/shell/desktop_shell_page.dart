import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_desktop_authorize/feature_desktop_authorize.dart';
import 'package:feature_terminal/feature_terminal.dart';

import 'shell_view_model.dart';

class DesktopShellPage extends ConsumerStatefulWidget {
  const DesktopShellPage({super.key});

  @override
  ConsumerState<DesktopShellPage> createState() => _DesktopShellPageState();
}

class _DesktopShellPageState extends ConsumerState<DesktopShellPage> {
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
    final shellState = ref.watch(shellViewModelProvider(ShellMode.desktop));
    final shellVm = ref.read(shellViewModelProvider(ShellMode.desktop).notifier);

    if (!authState.initialized || authState.isInitializing) {
      return const _DesktopShellBootstrapScreen();
    }

    if (!authState.isAuthenticated) {
      return const AuthPage(clientType: 'desktop');
    }

    final session = authState.session!;
    final sections = [
      _DesktopShellSection(
        label: context.l10n.terminal,
        icon: Icons.terminal_rounded,
        child: TerminalPage(
          accessToken: session.accessToken,
          deviceId: authorizeState.registeredDeviceId,
        ),
      ),
      _DesktopShellSection(
        label: context.l10n.authorize,
        icon: Icons.verified_user_outlined,
        child: DesktopAuthorizePage(authSession: session),
      ),
      _DesktopShellSection(
        label: context.l10n.account,
        icon: Icons.person_outline_rounded,
        child: _DesktopAccountPage(
          username: session.username,
          onLogout: () {
            ref.read(authViewModelProvider('desktop').notifier).logout();
            shellVm.reset();
          },
        ),
      ),
    ];
    final selectedIndex = shellState.selectedIndex.clamp(0, sections.length - 1);

    return Scaffold(
      body: Stack(
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF090C11), Color(0xFF0D1117), Color(0xFF080B10)],
              ),
            ),
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final horizontalPadding = constraints.maxWidth >= 1440
                      ? 28.0
                      : constraints.maxWidth >= 1220
                          ? 22.0
                          : 16.0;
                  final shellRadius = constraints.maxWidth >= 1220 ? 22.0 : 18.0;
                  final compactHeader = constraints.maxWidth < 1180;
                  final activeSection = sections[selectedIndex];

                  return Padding(
                    padding: EdgeInsets.all(horizontalPadding),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xF012171D),
                        borderRadius: BorderRadius.circular(shellRadius),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      ),
                      child: Column(
                        children: [
                          DesktopAuthorizeBootstrap(authSession: session),
                          _DesktopShellHeader(
                            sections: sections,
                            selectedIndex: selectedIndex,
                            compact: compactHeader,
                            username: session.username,
                            registeredDeviceId: authorizeState.registeredDeviceId,
                            onSelect: shellVm.selectIndex,
                            onLogout: () {
                              ref.read(authViewModelProvider('desktop').notifier).logout();
                              shellVm.reset();
                            },
                          ),
                          const Divider(height: 1),
                          Expanded(child: activeSection.child),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const DesktopAuthorizeRequestOverlay(),
        ],
      ),
    );
  }
}

class _DesktopShellBootstrapScreen extends StatelessWidget {
  const _DesktopShellBootstrapScreen();

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

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

class _DesktopShellHeader extends StatelessWidget {
  const _DesktopShellHeader({
    required this.sections,
    required this.selectedIndex,
    required this.compact,
    required this.username,
    required this.registeredDeviceId,
    required this.onSelect,
    required this.onLogout,
  });

  final List<_DesktopShellSection> sections;
  final int selectedIndex;
  final bool compact;
  final String username;
  final String? registeredDeviceId;
  final ValueChanged<int> onSelect;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final navChildren = [
      for (var index = 0; index < sections.length; index++)
        _DesktopNavChip(
          label: sections[index].label,
          icon: sections[index].icon,
          selected: index == selectedIndex,
          onTap: () => onSelect(index),
        ),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(16, compact ? 14 : 16, 16, compact ? 12 : 14),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DesktopBrandRow(
                  username: username,
                  registeredDeviceId: registeredDeviceId,
                  onLogout: onLogout,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: navChildren,
                ),
              ],
            )
          : Row(
              children: [
                Text('RemoteTerm', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(width: 18),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: navChildren),
                  ),
                ),
                const SizedBox(width: 12),
                _DesktopStatusPill(registeredDeviceId: registeredDeviceId),
                const SizedBox(width: 12),
                CircleAvatar(
                  radius: 16,
                  backgroundColor: palette.surfaceRaised,
                  child: Text(username.isEmpty ? 'F' : username[0].toUpperCase()),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: onLogout,
                  child: Text(context.l10n.logout),
                ),
              ],
            ),
    );
  }
}

class _DesktopBrandRow extends StatelessWidget {
  const _DesktopBrandRow({
    required this.username,
    required this.registeredDeviceId,
    required this.onLogout,
  });

  final String username;
  final String? registeredDeviceId;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('RemoteTerm', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                registeredDeviceId ?? context.l10n.desktopNodeActive,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                      fontFamily: 'JetBrains Mono',
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _DesktopStatusPill(registeredDeviceId: registeredDeviceId),
        const SizedBox(width: 10),
        CircleAvatar(
          radius: 16,
          backgroundColor: palette.surfaceRaised,
          child: Text(username.isEmpty ? 'F' : username[0].toUpperCase()),
        ),
        const SizedBox(width: 10),
        TextButton(
          onPressed: onLogout,
          child: Text(context.l10n.logout),
        ),
      ],
    );
  }
}

class _DesktopStatusPill extends StatelessWidget {
  const _DesktopStatusPill({
    required this.registeredDeviceId,
  });

  final String? registeredDeviceId;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: registeredDeviceId != null ? palette.primaryBright : palette.textMuted,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            (registeredDeviceId ?? context.l10n.desktopNodeActive).toUpperCase(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textSecondary,
                  fontFamily: 'JetBrains Mono',
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _DesktopNavChip extends StatelessWidget {
  const _DesktopNavChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? palette.primaryBright.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? palette.primaryBright.withValues(alpha: 0.24) : Colors.white.withValues(alpha: 0.04),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? palette.primaryBright : palette.textMuted,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: selected ? palette.primaryBright : palette.textMuted,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopAccountPage extends StatelessWidget {
  const _DesktopAccountPage({
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                child: Text(username.isEmpty ? 'F' : username[0].toUpperCase()),
              ),
              const SizedBox(height: 16),
              Text(username, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 10),
              Text(
                context.l10n.desktopAccountReady,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.sirix.textMuted,
                    ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onLogout,
                icon: const Icon(Icons.logout_rounded),
                label: Text(context.l10n.logout),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopShellSection {
  const _DesktopShellSection({
    required this.label,
    required this.icon,
    required this.child,
  });

  final String label;
  final IconData icon;
  final Widget child;
}
