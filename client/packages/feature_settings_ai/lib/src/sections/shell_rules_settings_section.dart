import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../ai_settings_view_model.dart';
import '../settings_ui.dart';

class ShellRulesSettingsSection extends StatefulWidget {
  const ShellRulesSettingsSection({
    super.key,
    required this.state,
    required this.vm,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;

  @override
  State<ShellRulesSettingsSection> createState() => _ShellRulesSettingsSectionState();
}

class _ShellRulesSettingsSectionState extends State<ShellRulesSettingsSection> {
  late final TextEditingController _allowController;
  late final TextEditingController _denyController;

  @override
  void initState() {
    super.initState();
    _allowController = TextEditingController();
    _denyController = TextEditingController();
    _syncControllers();
  }

  @override
  void didUpdateWidget(covariant ShellRulesSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.shellRules != widget.state.shellRules) {
      _syncControllers();
    }
  }

  @override
  void dispose() {
    _allowController.dispose();
    _denyController.dispose();
    super.dispose();
  }

  void _syncControllers() {
    _allowController.text = widget.state.shellRules.allow.join('\n');
    _denyController.text = widget.state.shellRules.deny.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final shellRules = widget.state.shellRules;

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        AiSettingsSectionHeader(
          title: 'Shell Rules',
          subtitle: 'Global shell authorization defaults. Workspace-specific overrides still live in the current workspace `.sirix/shell-rules.json`.',
        ),
        AiSettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Authorization Mode',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Allow permits everything except deny-list prefixes. Ask opens the Sirix runtime approval flow. Deny blocks every command, including allow-list entries.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                    ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<ApprovalMode>(
                key: ValueKey('shell-rules-mode-${shellRules.mode.name}'),
                initialValue: shellRules.mode,
                decoration: const InputDecoration(labelText: 'Mode'),
                items: ApprovalMode.values
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text(_approvalModeLabel(mode)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (mode) {
                  if (mode == null) {
                    return;
                  }
                  widget.vm.updateShellRules(shellRules.copyWith(mode: mode));
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < 860;
            final allowCard = _RuleListEditor(
              title: 'Allow Prefixes',
              subtitle: 'Used when mode is `allow` or after you persist an allow decision from the runtime.',
              hintText: 'git status\ngit diff',
              controller: _allowController,
              accentColor: palette.primaryBright,
              onChanged: (value) {
                widget.vm.updateShellRules(
                  shellRules.copyWith(allow: _parseRuleLines(value)),
                );
              },
            );
            final denyCard = _RuleListEditor(
              title: 'Deny Prefixes',
              subtitle: 'Applied in both `allow` and `ask` modes. Default protections such as `rm -rf` should stay here unless you have a strong reason.',
              hintText: 'rm -rf\nsudo rm',
              controller: _denyController,
              accentColor: palette.error,
              onChanged: (value) {
                widget.vm.updateShellRules(
                  shellRules.copyWith(deny: _parseRuleLines(value)),
                );
              },
            );

            if (stacked) {
              return Column(
                children: [
                  allowCard,
                  const SizedBox(height: 16),
                  denyCard,
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: allowCard),
                const SizedBox(width: 16),
                Expanded(child: denyCard),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _RuleListEditor extends StatelessWidget {
  const _RuleListEditor({
    required this.title,
    required this.subtitle,
    required this.hintText,
    required this.controller,
    required this.accentColor,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final String hintText;
  final TextEditingController controller;
  final Color accentColor;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return AiSettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            minLines: 10,
            maxLines: 14,
            onChanged: onChanged,
            decoration: InputDecoration(
              labelText: 'One command prefix per line',
              hintText: hintText,
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

List<String> _parseRuleLines(String raw) {
  return raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
}

String _approvalModeLabel(ApprovalMode mode) {
  return switch (mode) {
    ApprovalMode.allow => 'Allow',
    ApprovalMode.ask => 'Ask',
    ApprovalMode.deny => 'Deny',
  };
}
