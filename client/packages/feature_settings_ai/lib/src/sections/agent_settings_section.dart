import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../settings_ui.dart';
import '../ai_settings_view_model.dart';

class AgentSettingsSection extends StatelessWidget {
  const AgentSettingsSection({
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
        AiSettingsSectionHeader(
          title: 'Agents',
          subtitle: 'Bind providers and models into reusable execution profiles, then tune how each profile uses tools, skills, MCP, and approvals.',
          action: FilledButton.icon(
            onPressed: () async {
              final created =
                  await _showAgentDialog(context, state: state, vm: vm, existing: null);
              if (created != null) {
                vm.upsertAgent(created);
              }
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add Agent'),
          ),
        ),
        if (state.config.agents.isEmpty)
          const AiSettingsEmptyState(text: 'No agents configured.'),
        for (final agent in state.config.agents) ...[
          AiSettingsCard(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(agent.name, style: Theme.of(context).textTheme.titleMedium),
                    ),
                    IconButton(
                      onPressed: () async {
                        final edited = await _showAgentDialog(
                          context,
                          state: state,
                          vm: vm,
                          existing: agent,
                        );
                        if (edited != null) {
                          vm.upsertAgent(edited);
                        }
                      },
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      onPressed: () => vm.removeAgent(agent.id),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AiSettingsChip(label: agent.id),
                    AiSettingsChip(label: 'provider=${agent.providerId}'),
                    AiSettingsChip(label: 'model=${agent.modelId}'),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 18,
                  runSpacing: 6,
                  children: [
                    AiSettingsToggleTile(
                      title: 'Enabled',
                      value: agent.enabled,
                      onChanged: (value) => vm.upsertAgent(agent.copyWith(enabled: value)),
                    ),
                    AiSettingsToggleTile(
                      title: 'Builtin Tools Enabled',
                      width: 320,
                      value: agent.builtinToolsEnabled,
                      onChanged: (value) => vm.upsertAgent(
                        agent.copyWith(builtinToolsEnabled: value),
                      ),
                    ),
                  ],
                ),
                if (agent.systemPrompt.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    agent.systemPrompt,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

Future<AgentConfigModel?> _showAgentDialog(
  BuildContext context, {
  required AiSettingsState state,
  required AiSettingsViewModel vm,
  required AgentConfigModel? existing,
}) async {
  final providers = state.config.providers;
  if (providers.isEmpty) {
    await showAiSettingsDialog<void>(
      context: context,
      title: 'No Provider Available',
      subtitle: 'Create at least one provider and one enabled model before you add an agent.',
      width: 460,
      child: const Text('Please create at least one provider and model first.'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
    return null;
  }

  final idController = TextEditingController(text: existing?.id ?? vm.createStableId('agent'));
  final nameController = TextEditingController(text: existing?.name ?? 'New Agent');
  final systemPromptController = TextEditingController(text: existing?.systemPrompt ?? '');
  final enabledSkillIdsController =
      TextEditingController(text: existing?.enabledSkillIds.join(',') ?? '');
  final disabledSkillIdsController =
      TextEditingController(text: existing?.disabledSkillIds.join(',') ?? '');
  final enabledMcpIdsController =
      TextEditingController(text: existing?.enabledMcpServerIds.join(',') ?? '');
  final disabledMcpIdsController =
      TextEditingController(text: existing?.disabledMcpServerIds.join(',') ?? '');
  final capabilityDrafts = (existing?.capabilityRules ?? const <AgentCapabilityRuleModel>[])
      .map(_CapabilityRuleDraft.fromModel)
      .toList(growable: true);
  if (capabilityDrafts.isEmpty) {
    capabilityDrafts.add(_CapabilityRuleDraft());
  }

  var providerId = existing?.providerId ?? '';
  if (providerId.isEmpty || providers.every((provider) => provider.id != providerId)) {
    providerId = providers.first.id;
  }

  List<AiModelConfig> modelsForProvider(String value) {
    return providers
            .firstWhere((provider) => provider.id == value)
            .models
            .where((model) => model.enabled)
            .toList(growable: false);
  }

  var models = modelsForProvider(providerId);
  if (models.isEmpty) {
    await showAiSettingsDialog<void>(
      context: context,
      title: 'No Enabled Model',
      subtitle: 'The selected provider currently has no enabled model.',
      width: 460,
      child: const Text('Please enable one model before creating an agent.'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
    return null;
  }

  var modelId = existing?.modelId ?? '';
  if (modelId.isEmpty || models.every((model) => model.id != modelId)) {
    modelId = models.first.id;
  }

  var enabled = existing?.enabled ?? true;
  var builtinToolsEnabled = existing?.builtinToolsEnabled ?? true;

  final submitted = await showAiSettingsDialog<bool>(
    context: context,
    title: existing == null ? 'Add Agent' : 'Edit Agent',
    subtitle: 'Choose the provider and model pair, then define the exact skills, MCP servers, and approval rules this agent should follow.',
    width: 760,
    child: StatefulBuilder(
      builder: (context, setState) {
        return AiSettingsFieldGroup(
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(labelText: 'Agent ID'),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Agent Name'),
            ),
            DropdownButtonFormField<String>(
              value: providerId,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: providers
                  .map((provider) => DropdownMenuItem(
                        value: provider.id,
                        child: Text('${provider.name} (${provider.id})'),
                      ))
                  .toList(growable: false),
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                final nextModels = modelsForProvider(value);
                if (nextModels.isEmpty) {
                  return;
                }
                setState(() {
                  providerId = value;
                  models = nextModels;
                  modelId = nextModels.first.id;
                });
              },
            ),
            DropdownButtonFormField<String>(
              value: modelId,
              decoration: const InputDecoration(labelText: 'Model'),
              items: models
                  .map((model) => DropdownMenuItem(
                        value: model.id,
                        child: Text('${model.displayName} (${model.id})'),
                      ))
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() => modelId = value);
                }
              },
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                AiSettingsToggleTile(
                  title: 'Enabled',
                  value: enabled,
                  onChanged: (value) => setState(() => enabled = value),
                ),
                AiSettingsToggleTile(
                  title: 'Builtin Tools Enabled',
                  width: 320,
                  value: builtinToolsEnabled,
                  onChanged: (value) => setState(() => builtinToolsEnabled = value),
                ),
              ],
            ),
            TextField(
              controller: systemPromptController,
              minLines: 5,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'System Prompt',
                border: OutlineInputBorder(),
              ),
            ),
            TextField(
              controller: enabledSkillIdsController,
              decoration: const InputDecoration(labelText: 'Enabled Skill IDs (comma separated)'),
            ),
            TextField(
              controller: disabledSkillIdsController,
              decoration: const InputDecoration(labelText: 'Disabled Skill IDs (comma separated)'),
            ),
            TextField(
              controller: enabledMcpIdsController,
              decoration:
                  const InputDecoration(labelText: 'Enabled MCP Server IDs (comma separated)'),
            ),
            TextField(
              controller: disabledMcpIdsController,
              decoration:
                  const InputDecoration(labelText: 'Disabled MCP Server IDs (comma separated)'),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Capability Rules',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 8),
            ...capabilityDrafts.asMap().entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: entry.value.keyController,
                        decoration: const InputDecoration(
                          labelText: 'Capability Key',
                          hintText: 'builtin.shell',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 170,
                      child: DropdownButtonFormField<ApprovalMode>(
                        value: entry.value.approvalMode,
                        decoration: const InputDecoration(labelText: 'Mode'),
                        items: ApprovalMode.values
                            .map((value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(_enumName(value)),
                                ))
                            .toList(growable: false),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => entry.value.approvalMode = value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: capabilityDrafts.length <= 1
                          ? null
                          : () => setState(() => capabilityDrafts.removeAt(entry.key)),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => capabilityDrafts.add(_CapabilityRuleDraft())),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add Rule'),
              ),
            ),
          ],
        );
      },
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
    ],
  );

  if (submitted != true) {
    return null;
  }

  return AgentConfigModel(
    id: idController.text.trim(),
    name: nameController.text.trim(),
    providerId: providerId,
    modelId: modelId,
    systemPrompt: systemPromptController.text,
    builtinToolsEnabled: builtinToolsEnabled,
    enabledSkillIds: _parseCsv(enabledSkillIdsController.text),
    disabledSkillIds: _parseCsv(disabledSkillIdsController.text),
    enabledMcpServerIds: _parseCsv(enabledMcpIdsController.text),
    disabledMcpServerIds: _parseCsv(disabledMcpIdsController.text),
    capabilityRules: _parseCapabilityDrafts(capabilityDrafts),
    enabled: enabled,
  );
}

List<String> _parseCsv(String raw) {
  return raw
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

List<AgentCapabilityRuleModel> _parseCapabilityDrafts(List<_CapabilityRuleDraft> drafts) {
  final rules = <AgentCapabilityRuleModel>[];
  for (final draft in drafts) {
    final key = draft.keyController.text.trim();
    if (key.isEmpty) {
      continue;
    }
    rules.add(AgentCapabilityRuleModel(key: key, approvalMode: draft.approvalMode));
  }
  return rules;
}

String _enumName(Object value) => value.toString().split('.').last;

class _CapabilityRuleDraft {
  _CapabilityRuleDraft({
    String key = '',
    this.approvalMode = ApprovalMode.allow,
  }) : keyController = TextEditingController(text: key);

  factory _CapabilityRuleDraft.fromModel(AgentCapabilityRuleModel model) {
    return _CapabilityRuleDraft(
      key: model.key,
      approvalMode: model.approvalMode,
    );
  }

  final TextEditingController keyController;
  ApprovalMode approvalMode;
}
