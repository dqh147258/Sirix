part of 'auth_page.dart';

class _DesktopAuthForm extends StatelessWidget {
  const _DesktopAuthForm({
    required this.clientType,
    required this.state,
    required this.vm,
    required this.l10n,
  });

  final String clientType;
  final AuthState state;
  final AuthViewModel vm;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final captionStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: palette.textMuted,
          fontFamily: 'JetBrains Mono',
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          child: Column(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: palette.primaryBright.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: palette.primaryBright.withValues(alpha: 0.24)),
                ),
                child: const Center(
                  child: SirixBrandMark(size: 34),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                clientType == 'desktop' ? l10n.desktopTitle : l10n.mobileTitle,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontSize: 34,
                      letterSpacing: -1.0,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.secureWorkspaceEntry.toUpperCase(),
                textAlign: TextAlign.center,
                style: captionStyle,
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
        Text(l10n.accountIdentity.toUpperCase(), style: captionStyle),
        const SizedBox(height: 10),
        TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.alternate_email_rounded),
            hintText: l10n.usernameHint,
          ),
          onChanged: vm.setUsername,
        ),
        const SizedBox(height: 18),
        Text(l10n.accessCredential.toUpperCase(), style: captionStyle),
        const SizedBox(height: 10),
        TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            hintText: l10n.passwordHint,
          ),
          obscureText: true,
          onChanged: vm.setPassword,
        ),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: palette.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: palette.error.withValues(alpha: 0.28)),
            ),
            child: Text(
              state.errorMessage!,
              style: TextStyle(color: palette.error),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: palette.surfaceRaised.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: palette.primaryBright,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.desktopLoginHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                        height: 1.45,
                      ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: state.isLoading ? null : vm.login,
            style: FilledButton.styleFrom(
              backgroundColor: palette.primary,
              foregroundColor: const Color(0xFF04110C),
              minimumSize: const Size.fromHeight(56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            icon: state.isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: Text(l10n.login),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: state.isLoading ? null : vm.register,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              foregroundColor: palette.textPrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(l10n.register),
          ),
        ),
      ],
    );
  }
}

class _AuthForm extends StatelessWidget {
  const _AuthForm({
    required this.clientType,
    required this.state,
    required this.vm,
    required this.isDesktop,
    required this.l10n,
  });

  final String clientType;
  final AuthState state;
  final AuthViewModel vm;
  final bool isDesktop;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final monoStyle = TextStyle(
      fontFamily: 'JetBrains Mono',
      color: palette.textSecondary,
      letterSpacing: 0.7,
    );
    final captionStyle = monoStyle.copyWith(
      fontSize: 10.5,
      color: palette.textMuted,
      fontWeight: FontWeight.w700,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isDesktop)
          Align(
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: palette.primaryBright.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: palette.primaryBright.withValues(alpha: 0.24)),
                  ),
                  child: const Center(
                    child: SirixBrandMark(size: 30),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  clientType == 'desktop' ? l10n.desktopTitle : l10n.mobileTitle,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 30),
                ),
                const SizedBox(height: 8),
                Text(
                  clientType == 'desktop' ? l10n.secureWorkspaceEntry : l10n.mobileWorkspaceEntry,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: palette.textSecondary,
                      ),
                ),
                const SizedBox(height: 28),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.loginPanelTitle,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 24),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.loginPanelSubtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: palette.textSecondary,
                      ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 18),
        Text(
          l10n.accountIdentity,
          style: captionStyle,
        ),
        const SizedBox(height: 10),
        TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.alternate_email_rounded),
            hintText: l10n.usernameHint,
          ),
          onChanged: vm.setUsername,
        ),
        const SizedBox(height: 18),
        Text(
          l10n.accessCredential,
          style: captionStyle,
        ),
        const SizedBox(height: 10),
        TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            hintText: l10n.passwordHint,
          ),
          obscureText: true,
          onChanged: vm.setPassword,
        ),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: palette.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: palette.error.withValues(alpha: 0.28)),
            ),
            child: Text(
              state.errorMessage!,
              style: TextStyle(color: palette.error),
            ),
          ),
        ],
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: state.isLoading ? null : vm.login,
            style: FilledButton.styleFrom(
              backgroundColor: palette.primary,
              foregroundColor: const Color(0xFF03110C),
              minimumSize: const Size.fromHeight(56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            icon: state.isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: Text(l10n.login),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: state.isLoading ? null : vm.register,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              side: BorderSide(color: palette.glassStroke),
              foregroundColor: palette.textPrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(l10n.register),
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: palette.surfaceRaised.withValues(alpha: 0.74),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.glassStroke),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: palette.primaryBright,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  clientType == 'desktop' ? l10n.desktopLoginHint : l10n.mobileLoginHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                        height: 1.45,
                      ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
