import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';

import 'desktop_shell_page.dart';
import 'mobile_shell_page.dart';

class SirixShellApp extends StatelessWidget {
  const SirixShellApp({super.key});

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
      title: 'Sirix',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkSirix(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: _useDesktopShell ? const DesktopShellPage() : const MobileShellPage(),
    );
  }
}
