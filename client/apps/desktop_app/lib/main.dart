import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:feature_auth/feature_auth.dart';
import 'package:feature_desktop_authorize/feature_desktop_authorize.dart';

void main() {
  runApp(const ProviderScope(child: DesktopApp()));
}

class DesktopApp extends StatelessWidget {
  const DesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Freeloom Desktop',
      theme: AppTheme.light(),
      home: const DesktopHomePage(),
    );
  }
}

class DesktopHomePage extends ConsumerWidget {
  const DesktopHomePage({super.key});

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
        body: const TabBarView(
          children: [
            DesktopAuthorizePage(),
            AuthPage(clientType: 'desktop'),
          ],
        ),
      ),
    );
  }
}
