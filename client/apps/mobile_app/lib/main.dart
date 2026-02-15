import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_device_list/feature_device_list.dart';
import 'package:feature_remote_view/feature_remote_view.dart';
import 'package:infra_api/infra_api.dart';

void main() {
  runApp(const ProviderScope(child: MobileApp()));
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

    final pages = [
      AuthPage(clientType: 'mobile'),
      DeviceListPage(
        accessToken: session.accessToken,
        onConnectSession: (value) => setState(() {
          _activeSession = value;
          _index = 2;
        }),
      ),
      RemoteViewPage(
        accessToken: session.accessToken,
        connectedSession: _activeSession,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Freeloom Mobile'),
        actions: [
          TextButton(
            onPressed: ref.read(authViewModelProvider('mobile').notifier).logout,
            child: const Text('退出'),
          ),
        ],
      ),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
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
