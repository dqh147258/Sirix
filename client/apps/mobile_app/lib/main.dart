import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_device_list/feature_device_list.dart';
import 'package:feature_remote_view/feature_remote_view.dart';
import 'package:infra_api/infra_api.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      AppLogger.configure(
        source: AppLogSource.flutterMobile,
        baseUrl: resolvedApiBaseUrl,
      );
      AppLogger.info(
        '[MEDIA_AUTH_TRACE] mobile app startup useMockBackend=$useMockBackend apiBaseUrl=$resolvedApiBaseUrl',
      );
      _installUnhandledErrorLogging();
      runApp(const ProviderScope(child: MobileApp()));
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

class MobileApp extends StatelessWidget {
  const MobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Freeloom Mobile',
      theme: AppTheme.light(),
      home: const MobileHomePage(),
    );
  }
}

class MobileHomePage extends ConsumerStatefulWidget {
  const MobileHomePage({super.key});

  @override
  ConsumerState<MobileHomePage> createState() => _MobileHomePageState();
}

class _MobileHomePageState extends ConsumerState<MobileHomePage> {
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
