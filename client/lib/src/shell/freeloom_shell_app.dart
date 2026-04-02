import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';

import 'desktop_shell_page.dart';
import 'mobile_shell_page.dart';

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
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkFreeloom(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: _useDesktopShell ? const DesktopShellPage() : const MobileShellPage(),
    );
  }
}
