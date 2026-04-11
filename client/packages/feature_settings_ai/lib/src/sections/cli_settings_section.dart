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
        const AiSettingsSectionHeader(
          title: 'CLI',
          subtitle: 'Global behavior injected ahead of per-agent instructions and used by every Sirix coding session.',
        ),
        AiSettingsCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AiSettingsToggleTile(
                title: 'Close Model Without Confirmation',
                subtitle: 'Skip the extra quit confirmation in the embedded CLI session.',
                value: state.config.cli.closeModelWithoutConfirmation,
                onChanged: vm.updateCloseModelWithoutConfirmation,
                width: double.infinity,
              ),
              const SizedBox(height: 18),
              Text(
                'Supplemental System Prompt',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Applied globally before per-agent system prompts.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                    ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: ValueKey(state.config.cli.supplementalSystemPrompt.hashCode),
                initialValue: state.config.cli.supplementalSystemPrompt,
                onChanged: vm.updateCliPrompt,
                maxLines: 14,
                minLines: 10,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Enter additional global instructions...',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
