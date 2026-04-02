import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';

import 'auth_state.dart';
import 'auth_view_model.dart';

part 'auth_page_backdrop.dart';
part 'auth_page_forms.dart';
part 'auth_page_panels.dart';

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
            center: const Alignment(0, -0.44),
            radius: 1.44,
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
                  return Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _MobileBrandHeader(clientType: clientType),
                            const SizedBox(height: 18),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                                child: DecoratedBox(
                                  decoration: AppTheme.glassDecoration(
                                    context,
                                    radius: 24,
                                    fillColor: const Color(0xA61B2026),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.08),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: state.session == null
                                        ? _AuthForm(
                                            clientType: clientType,
                                            state: state,
                                            vm: vm,
                                            isDesktop: false,
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
                            _AuthFooter(clientType: clientType, isDesktop: false),
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
                    width: 420,
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
