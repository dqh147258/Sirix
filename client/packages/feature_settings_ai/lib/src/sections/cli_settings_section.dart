import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';

import '../ai_settings_state.dart';
import '../settings_ui.dart';
import '../ai_settings_view_model.dart';

class CliSettingsSection extends StatelessWidget {
  const CliSettingsSection({
    super.key,
    required this.state,
    required this.vm,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return ListView(
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 32),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: palette.surfaceRaised,
            borderRadius: BorderRadius.circular(12),
            border: Border(
              left: BorderSide(color: palette.primaryBright, width: 4),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CLI SETTINGS',
                style: TextStyle(
                  fontFamily: 'Space Grotesk',
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: palette.primaryBright,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Global behavior injected ahead of per-agent instructions and used by every Sirix coding session.',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: palette.surfaceMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.glassStroke),
                ),
                child: AiSettingsToggleTile(
                  title: 'Close Model Without Confirmation',
                  subtitle: 'Skip the extra quit confirmation in the embedded CLI session.',
                  value: state.config.cli.closeModelWithoutConfirmation,
                  onChanged: vm.updateCloseModelWithoutConfirmation,
                  width: double.infinity,
                ),
              ),
            ],
          ),
        ),
        
        Row(
          children: [
            Icon(Icons.terminal_rounded, color: palette.secondary, size: 24),
            const SizedBox(width: 12),
            Text(
              'SUPPLEMENTAL SYSTEM PROMPT',
              style: TextStyle(
                fontFamily: 'Space Grotesk',
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 2.0,
                color: palette.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Applied globally before per-agent system prompts. Use this to configure strict formatting, persistent context, or custom instructions across all coding sessions.',
          style: TextStyle(
            color: palette.textMuted,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: palette.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.glassStroke),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: TextFormField(
            key: ValueKey(state.config.cli.supplementalSystemPrompt.hashCode),
            initialValue: state.config.cli.supplementalSystemPrompt,
            onChanged: vm.updateCliPrompt,
            maxLines: 18,
            minLines: 12,
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 13,
              color: palette.primaryBright.withValues(alpha: 0.9),
              height: 1.5,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(20),
              hintText: 'Enter additional global instructions...',
              hintStyle: TextStyle(
                color: palette.textMuted.withValues(alpha: 0.5),
                fontFamily: 'JetBrains Mono',
              ),
            ),
          ),
        ),
      ],
    );
  }
}
