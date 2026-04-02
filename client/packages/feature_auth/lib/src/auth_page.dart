import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';

import 'auth_state.dart';
import 'auth_view_model.dart';

class AuthPage extends ConsumerWidget {
  const AuthPage({
    super.key,
    required this.clientType,
    this.onLoginSuccess,
  });

  final String clientType;
  final VoidCallback? onLoginSuccess;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(authViewModelProvider(clientType));
    final vm = ref.read(authViewModelProvider(clientType).notifier);
    final l10n = context.l10n;
    final isDesktop = MediaQuery.sizeOf(context).width >= 900;

    ref.listen<AuthState>(authViewModelProvider(clientType), (previous, next) {
      if ((previous?.isAuthenticated ?? false) == false && next.isAuthenticated) {
        onLoginSuccess?.call();
      }
    });

    if (isDesktop) {
      return _DesktopAuthScreen(
        clientType: clientType,
        state: state,
        vm: vm,
        l10n: l10n,
      );
    }

    final palette = context.freeloom;

    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: isDesktop ? const Alignment(0.12, -0.28) : const Alignment(0, -0.44),
            radius: isDesktop ? 1.18 : 1.44,
            colors: [
              const Color(0xFF1A2028),
              palette.background,
              const Color(0xFF080C11),
            ],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _AuthBackdrop(),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final contentWidth = isDesktop ? 452.0 : 420.0;
                  return Center(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(
                        horizontal: isDesktop ? 32 : 20,
                        vertical: isDesktop ? 28 : 24,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: contentWidth),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isDesktop) ...[
                              _MobileBrandHeader(clientType: clientType),
                              const SizedBox(height: 18),
                            ],
                            ClipRRect(
                              borderRadius: BorderRadius.circular(isDesktop ? 28 : 24),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                                child: DecoratedBox(
                                  decoration: AppTheme.glassDecoration(
                                    context,
                                    radius: isDesktop ? 28 : 24,
                                    fillColor: const Color(0xA61B2026),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.08),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(isDesktop ? 30 : 24),
                                    child: state.session == null
                                        ? _AuthForm(
                                            clientType: clientType,
                                            state: state,
                                            vm: vm,
                                            isDesktop: isDesktop,
                                            l10n: l10n,
                                          )
                                        : _AccountPanel(
                                            sessionName: state.session!.username,
                                            clientType: clientType,
                                            l10n: l10n,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            _AuthFooter(clientType: clientType, isDesktop: isDesktop),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: -60,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    width: isDesktop ? 880 : 420,
                    height: 180,
                    decoration: BoxDecoration(
                      color: palette.primaryBright.withValues(alpha: 0.09),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: palette.primaryBright.withValues(alpha: 0.12),
                          blurRadius: 120,
                          spreadRadius: 12,
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
    );
  }
}

class _DesktopAuthScreen extends StatelessWidget {
  const _DesktopAuthScreen({
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
    final palette = context.freeloom;

    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.18, -0.26),
            radius: 1.18,
            colors: [
              const Color(0xFF162028),
              palette.background,
              const Color(0xFF070A0D),
            ],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _DesktopAuthBlueprintBackdrop(),
            Positioned(
              left: 0,
              right: 0,
              bottom: -90,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    width: 980,
                    height: 240,
                    decoration: BoxDecoration(
                      color: palette.primaryBright.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: palette.primaryBright.withValues(alpha: 0.12),
                          blurRadius: 140,
                          spreadRadius: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(32),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                            child: DecoratedBox(
                              decoration: AppTheme.glassDecoration(
                                context,
                                radius: 32,
                                fillColor: const Color(0x99181D21),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: state.session == null
                                    ? _DesktopAuthForm(
                                        clientType: clientType,
                                        state: state,
                                        vm: vm,
                                        l10n: l10n,
                                      )
                                    : _AccountPanel(
                                        sessionName: state.session!.username,
                                        clientType: clientType,
                                        l10n: l10n,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'v4.0.2  |  CORE STABLE',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: palette.textMuted,
                                    fontFamily: 'JetBrains Mono',
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2,
                                  ),
                            ),
                            Text(
                              'AES-256-GCM',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: palette.textMuted,
                                    fontFamily: 'JetBrains Mono',
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2,
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

class _DesktopAuthBlueprintBackdrop extends StatelessWidget {
  const _DesktopAuthBlueprintBackdrop();

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DotGridPainter(color: Colors.white.withValues(alpha: 0.05)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(28),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.surface.withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(38),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  flex: 7,
                  child: Column(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.surface.withValues(alpha: 0.44),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                        ),
                        child: const SizedBox(height: 86),
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.36),
                            borderRadius: BorderRadius.circular(38),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              children: [
                                Row(
                                  children: List.generate(
                                    4,
                                    (index) => Expanded(
                                      child: Padding(
                                        padding: EdgeInsets.only(right: index == 3 ? 0 : 16),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: palette.surfaceRaised.withValues(alpha: 0.78),
                                            borderRadius: BorderRadius.circular(22),
                                          ),
                                          child: const SizedBox(height: 120),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Expanded(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: palette.background.withValues(alpha: 0.72),
                                      borderRadius: BorderRadius.circular(30),
                                      border: Border.all(color: palette.glassStroke),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
    final palette = context.freeloom;
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
                child: Icon(
                  clientType == 'desktop' ? Icons.terminal_rounded : Icons.monitor_rounded,
                  color: palette.primaryBright,
                  size: 30,
                ),
              ),
              const SizedBox(height: 18),
              RichText(
                text: TextSpan(
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontSize: 34,
                        letterSpacing: -1.0,
                      ),
                  children: [
                    const TextSpan(text: 'RemoteTerm '),
                    TextSpan(
                      text: 'Pro',
                      style: TextStyle(color: palette.primaryBright),
                    ),
                  ],
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

class _AuthBackdrop extends StatelessWidget {
  const _AuthBackdrop();

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final isDesktop = MediaQuery.sizeOf(context).width >= 900;

    if (!isDesktop) {
      return Stack(
        children: [
          Positioned(
            top: -80,
            right: -40,
            child: _GlowOrb(
              color: palette.primaryBright.withValues(alpha: 0.13),
              size: 260,
            ),
          ),
          Positioned(
            left: -100,
            bottom: 80,
            child: _GlowOrb(
              color: palette.secondary.withValues(alpha: 0.12),
              size: 240,
            ),
          ),
        ],
      );
    }

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DotGridPainter(color: Colors.white.withValues(alpha: 0.06)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(28),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.surface.withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(36),
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  flex: 7,
                  child: Column(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.surface.withValues(alpha: 0.46),
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: const SizedBox(height: 86),
                      ),
                      const SizedBox(height: 18),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.38),
                            borderRadius: BorderRadius.circular(36),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              children: [
                                Row(
                                  children: List.generate(
                                    4,
                                    (index) => Expanded(
                                      child: Padding(
                                        padding: EdgeInsets.only(right: index == 3 ? 0 : 16),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: palette.surfaceRaised.withValues(alpha: 0.8),
                                            borderRadius: BorderRadius.circular(22),
                                          ),
                                          child: const SizedBox(height: 120),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Expanded(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: palette.background.withValues(alpha: 0.74),
                                      borderRadius: BorderRadius.circular(28),
                                      border: Border.all(color: palette.glassStroke),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({
    required this.color,
    required this.size,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size),
        boxShadow: [
          BoxShadow(
            color: color,
            blurRadius: size * 0.45,
            spreadRadius: 10,
          ),
        ],
      ),
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
    final palette = context.freeloom;
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
                  child: Icon(
                    clientType == 'desktop' ? Icons.terminal_rounded : Icons.monitor_rounded,
                    color: palette.primaryBright,
                    size: 28,
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
          clientType == 'desktop'
              ? l10n.desktopAccountReady
              : l10n.mobileAccountReady,
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

class _DotGridPainter extends CustomPainter {
  const _DotGridPainter({
    required this.color,
  });

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (double x = 12; x < size.width; x += 18) {
      for (double y = 12; y < size.height; y += 18) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) => oldDelegate.color != color;
}
