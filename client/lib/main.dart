import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_desktop_authorize/feature_desktop_authorize.dart';
import 'package:feature_device_list/feature_device_list.dart';
import 'package:feature_remote_view/feature_remote_view.dart';
import 'package:infra_api/infra_api.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      final source = switch (defaultTargetPlatform) {
        TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux =>
          AppLogSource.flutterDesktop,
        _ => AppLogSource.flutterMobile,
      };
      AppLogger.configure(
        source: source,
        baseUrl: resolvedApiBaseUrl,
      );
      AppLogger.info(
        '[MEDIA_AUTH_TRACE] shell app startup useMockBackend=$useMockBackend apiBaseUrl=$resolvedApiBaseUrl platform=$defaultTargetPlatform',
      );
      _installUnhandledErrorLogging();
      runApp(const ProviderScope(child: FreeloomShellApp()));
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

class FreeloomShellApp extends StatelessWidget {
  const FreeloomShellApp({super.key});

  bool get _useDesktopShell {
    if (kIsWeb) {
      return false;
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _useDesktopShell ? 'Freeloom Desktop' : 'Freeloom Mobile',
      theme: AppTheme.light(),
      home: _useDesktopShell ? const _DesktopHomePage() : const _MobileHomePage(),
    );
  }
}

class _DesktopHomePage extends ConsumerWidget {
  const _DesktopHomePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authViewModelProvider('desktop'));

    if (!authState.isAuthenticated) {
      return Scaffold(
        appBar: AppBar(title: const Text('Freeloom Desktop 登录')),
        body: const AuthPage(clientType: 'desktop'),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Freeloom Desktop'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '授权'),
              Tab(text: '账号'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: ref.read(authViewModelProvider('desktop').notifier).logout,
              child: const Text('退出'),
            ),
          ],
        ),
        body: TabBarView(
          children: [
            DesktopAuthorizePage(authSession: authState.session),
            const AuthPage(clientType: 'desktop'),
          ],
        ),
      ),
    );
  }
}

class _MobileHomePage extends ConsumerStatefulWidget {
  const _MobileHomePage();

  @override
  ConsumerState<_MobileHomePage> createState() => _MobileHomePageState();
}

class _MobileHomePageState extends ConsumerState<_MobileHomePage> {
  int _index = 0;
  RemoteSessionSummary? _activeSession;

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authViewModelProvider('mobile'));
    final session = authState.session;

    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Freeloom Mobile 登录')),
        body: AuthPage(
          clientType: 'mobile',
          onLoginSuccess: () => setState(() {}),
        ),
      );
    }

    final remoteViewState = ref.watch(remoteViewViewModelProvider);
    final remoteLandscapeFullscreen = _index == 2 &&
        remoteViewState.sessionId != null &&
        remoteViewState.orientationMode == ViewOrientationMode.landscape;

    final pages = [
      AuthPage(clientType: 'mobile'),
      DeviceListPage(
        accessToken: session.accessToken,
        onConnectSession: (value) {
          setState(() {
            _activeSession = value;
            _index = 2;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final nextSession = value;
            if (!mounted) {
              return;
            }
            AppLogger.info(
              '[MEDIA_STREAM_TRACE] mobile auto attach sessionId=${nextSession.sessionId} state=${nextSession.state}',
            );
            ref.read(remoteViewViewModelProvider.notifier).attachSession(
                  sessionId: nextSession.sessionId,
                  deviceId: nextSession.targetDeviceId,
                  accessToken: session.accessToken,
                  initialState: nextSession.state,
                );
          });
        },
      ),
      RemoteViewPage(
        accessToken: session.accessToken,
        connectedSession: _activeSession,
      ),
    ];

    return Scaffold(
      appBar: remoteLandscapeFullscreen
          ? null
          : AppBar(
              title: const Text('Freeloom Mobile'),
              actions: [
                TextButton(
                  onPressed: ref.read(authViewModelProvider('mobile').notifier).logout,
                  child: const Text('退出'),
                ),
              ],
            ),
      body: pages[_index],
      bottomNavigationBar: remoteLandscapeFullscreen
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '账号',
                ),
                NavigationDestination(
                  icon: Icon(Icons.computer_outlined),
                  selectedIcon: Icon(Icons.computer),
                  label: '设备',
                ),
                NavigationDestination(
                  icon: Icon(Icons.live_tv_outlined),
                  selectedIcon: Icon(Icons.live_tv),
                  label: '远程查看',
                ),
              ],
            ),
    );
  }
}
