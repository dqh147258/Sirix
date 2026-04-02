part of 'auth_page.dart';

class _AccountPanel extends StatelessWidget {
  const _AccountPanel({
    required this.sessionName,
    required this.clientType,
    required this.l10n,
  });

  final String sessionName;
  final String clientType;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final scheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: palette.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(
            clientType == 'desktop' ? Icons.desktop_windows_rounded : Icons.phone_iphone_rounded,
            color: palette.primaryBright,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          l10n.currentAccount,
          style: scheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          sessionName,
          style: scheme.headlineMedium?.copyWith(fontSize: 32),
        ),
        const SizedBox(height: 12),
        Text(
          clientType == 'desktop' ? l10n.desktopAccountReady : l10n.mobileAccountReady,
          style: scheme.bodyMedium?.copyWith(color: palette.textSecondary, height: 1.5),
        ),
      ],
    );
  }
}

class _MobileBrandHeader extends StatelessWidget {
  const _MobileBrandHeader({
    required this.clientType,
  });

  final String clientType;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: palette.surfaceRaised.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 26,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Icon(
            clientType == 'desktop' ? Icons.terminal_rounded : Icons.monitor_heart_rounded,
            color: palette.primaryBright,
            size: 34,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          clientType == 'desktop' ? l10n.desktopTitle : l10n.mobileTitle,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 34),
        ),
        const SizedBox(height: 6),
        Text(
          clientType == 'desktop' ? l10n.secureWorkspaceEntry : l10n.mobileWorkspaceEntry,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: palette.textMuted,
                fontFamily: 'JetBrains Mono',
                letterSpacing: 1.2,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _AuthFooter extends StatelessWidget {
  const _AuthFooter({
    required this.clientType,
    required this.isDesktop,
  });

  final String clientType;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: palette.surface.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.glassStroke),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: palette.primaryBright.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: palette.primaryBright,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              Text(
                clientType == 'desktop' ? l10n.desktopFooterStatus : l10n.mobileFooterStatus,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textSecondary,
                      fontFamily: 'JetBrains Mono',
                      letterSpacing: 0.9,
                    ),
              ),
            ],
          ),
        ),
        if (!isDesktop) ...[
          const SizedBox(height: 12),
          Text(
            l10n.authFooterAgreements,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                  height: 1.5,
                ),
          ),
        ],
      ],
    );
  }
}
