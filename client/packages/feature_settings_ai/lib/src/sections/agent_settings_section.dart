import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../ai_settings_view_model.dart';
import '../settings_ui.dart';

class AgentSettingsSection extends StatefulWidget {
  const AgentSettingsSection({
    super.key,
    required this.state,
    required this.vm,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;

  @override
  State<AgentSettingsSection> createState() => _AgentSettingsSectionState();
}

class _AgentSettingsSectionState extends State<AgentSettingsSection> {
  String? _selectedAgentId;

  @override
  void initState() {
    super.initState();
    if (widget.state.config.agents.isNotEmpty) {
      _selectedAgentId = widget.state.config.agents.first.id;
    }
  }

  @override
  void didUpdateWidget(covariant AgentSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedAgentId != null &&
        !widget.state.config.agents.any((agent) => agent.id == _selectedAgentId)) {
      _selectedAgentId = null;
    }
    if (_selectedAgentId == null && widget.state.config.agents.isNotEmpty) {
      _selectedAgentId = widget.state.config.agents.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 880;
        final listPane = _AgentListPane(
          state: widget.state,
          selectedAgentId: _selectedAgentId,
          compact: constraints.maxWidth < 1180 && !stacked,
          onSelect: (agentId) => setState(() => _selectedAgentId = agentId),
          onCreate: () async {
            final created = await _showAgentDialog(
              context,
              state: widget.state,
              vm: widget.vm,
              existing: null,
            );
            if (created == null) {
              return;
            }
            widget.vm.upsertAgent(created);
            setState(() => _selectedAgentId = created.id);
          },
        );

        final selectedAgent = _selectedAgentId == null
            ? null
            : widget.state.config.agents.firstWhere(
                (agent) => agent.id == _selectedAgentId,
              );
        final detailPane = selectedAgent == null
            ? const AiSettingsEmptyState(text: 'Select an agent or create a new profile.')
            : _AgentDetailPane(
                agent: selectedAgent,
                state: widget.state,
                vm: widget.vm,
                onEdit: () async {
                  final updated = await _showAgentDialog(
                    context,
                    state: widget.state,
                    vm: widget.vm,
                    existing: selectedAgent,
                  );
                  if (updated != null) {
                    widget.vm.upsertAgent(updated);
                  }
                },
              );

        if (stacked) {
          return ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              listPane,
              const SizedBox(height: 16),
              detailPane,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: constraints.maxWidth < 1180 ? 280 : 320, child: listPane),
            const SizedBox(width: 16),
            Expanded(child: detailPane),
          ],
        );
      },
    );
  }
}

class _AgentListPane extends StatelessWidget {
  const _AgentListPane({
    required this.state,
    required this.selectedAgentId,
    required this.compact,
    required this.onSelect,
    required this.onCreate,
  });

  final AiSettingsState state;
  final String? selectedAgentId;
  final bool compact;
  final ValueChanged<String> onSelect;
  final Future<void> Function() onCreate;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return AiSettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AiSettingsSectionHeader(
            title: 'Agent Profiles',
            subtitle: 'Switch between local runtime profiles and manage the exact tools, MCP servers, skills, and fallback model each one can use.',
            action: FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New Agent'),
            ),
          ),
          if (state.config.agents.isEmpty)
            const AiSettingsEmptyState(text: 'No agents configured yet.')
          else
            Column(
              children: [
                for (final agent in state.config.agents)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => onSelect(agent.id),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: agent.id == selectedAgentId
                                ? palette.surfaceMuted.withValues(alpha: 0.52)
                                : palette.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: agent.id == selectedAgentId
                                  ? palette.primaryBright.withValues(alpha: 0.4)
                                  : palette.glassStroke,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: agent.enabled
                                      ? palette.primaryBright.withValues(alpha: 0.16)
                                      : palette.surfaceMuted,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.smart_toy_rounded,
                                  size: 18,
                                  color: agent.enabled
                                      ? palette.primaryBright
                                      : palette.textMuted,
                                ),
                              ),
                              if (!compact) ...[
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        agent.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        agent.description.trim().isEmpty
                                            ? agent.id
                                            : agent.description,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: palette.textMuted,
                                            ),
                                      ),
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          AiSettingsChip(label: agent.providerId),
                                          AiSettingsChip(label: agent.modelId),
                                          AiSettingsChip(
                                            label: agent.enabled ? 'Enabled' : 'Disabled',
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _AgentDetailPane extends StatelessWidget {
  const _AgentDetailPane({
    required this.agent,
    required this.state,
    required this.vm,
    required this.onEdit,
  });

  final AgentConfigModel agent;
  final AiSettingsState state;
  final AiSettingsViewModel vm;
  final Future<void> Function() onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final skills = state.config.skills.where((item) => agent.skillIds.contains(item.id)).toList();
    final mcpServers =
        state.config.mcpServers.where((item) => agent.mcpServerIds.contains(item.id)).toList();
    final subAgents = state.config.agents
        .where((item) => agent.subAgentIds.contains(item.id))
        .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        AiSettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          agent.name,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          agent.description.trim().isEmpty
                              ? 'No description provided for this agent.'
                              : agent.description,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: palette.textMuted,
                              ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            AiSettingsChip(label: 'id: ${agent.id}'),
                            AiSettingsChip(label: agent.providerId),
                            AiSettingsChip(label: agent.modelId),
                            AiSettingsChip(label: _approvalModeLabel(agent.approvalMode)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Switch(
                    value: agent.enabled,
                    onChanged: (value) => vm.upsertAgent(agent.copyWith(enabled: value)),
                    activeThumbColor: palette.primaryBright,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_rounded),
                    label: const Text('Edit Agent'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _showPromptPreviewDialog(
                      context,
                      vm: vm,
                      state: state,
                      config: state.config,
                      agent: agent,
                    ),
                    icon: const Icon(Icons.preview_rounded),
                    label: const Text('Preview System Prompt'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => vm.removeAgent(agent.id),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Delete Agent'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < 940;
            final identityCard = AiSettingsCard(
              child: _InfoList(
                rows: [
                  ('Description', agent.description),
                  ('Primary Provider', agent.providerId),
                  ('Primary Model', agent.modelId),
                  (
                    'Fallback',
                    agent.fallbackProviderId.trim().isEmpty || agent.fallbackModelId.trim().isEmpty
                        ? 'Not configured'
                        : '${agent.fallbackProviderId} / ${agent.fallbackModelId}',
                  ),
                  ('Shell Authorization', _approvalModeLabel(agent.approvalMode)),
                ],
              ),
            );
            final accessCard = AiSettingsCard(
              child: _InfoList(
                rows: [
                  ('Builtin Tools', '${agent.builtinToolIds.length} selected'),
                  ('Skills', skills.isEmpty ? 'None selected' : skills.map((item) => item.name).join(', ')),
                  ('MCP Servers', mcpServers.isEmpty ? 'None selected' : mcpServers.map((item) => item.name).join(', ')),
                  ('Sub Agents', subAgents.isEmpty ? 'None selected' : subAgents.map((item) => item.name).join(', ')),
                ],
              ),
            );

            if (stacked) {
              return Column(
                children: [
                  identityCard,
                  const SizedBox(height: 16),
                  accessCard,
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: identityCard),
                const SizedBox(width: 16),
                Expanded(child: accessCard),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        AiSettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Custom System Prompt',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                agent.systemPrompt.trim().isEmpty
                    ? 'No additional system prompt has been configured for this agent.'
                    : agent.systemPrompt,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: agent.systemPrompt.trim().isEmpty
                          ? palette.textMuted
                          : palette.textSecondary,
                      height: 1.55,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoList extends StatelessWidget {
  const _InfoList({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows) ...[
          Text(
            row.$1,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: palette.textMuted,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            row.$2.trim().isEmpty ? 'Not set' : row.$2,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: palette.textSecondary,
                  height: 1.45,
                ),
          ),
          if (row != rows.last) const SizedBox(height: 16),
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
  final providers = state.config.providers
      .where((provider) => provider.enabled)
      .toList(growable: false);
  if (providers.isEmpty) {
    await showAiSettingsDialog<void>(
      context: context,
      title: 'No Provider Available',
      subtitle: 'Create at least one enabled provider and one enabled text model before adding an agent.',
      width: 460,
      child: const Text('Please create and enable a provider first.'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
    return null;
  }

  List<AiModelConfig> textModelsForProvider(String providerId) {
    final provider = providers.firstWhere((item) => item.id == providerId);
    return provider.models
        .where((model) => model.enabled && model.modelKind == ModelKind.text)
        .toList(growable: false);
  }

  final idController = TextEditingController(
    text: existing?.id ?? vm.createStableId('agent'),
  );
  final nameController = TextEditingController(
    text: existing?.name ?? 'New Agent',
  );
  final descriptionController = TextEditingController(
    text: existing?.description ?? '',
  );
  final systemPromptController = TextEditingController(
    text: existing?.systemPrompt ?? '',
  );

  var providerId = existing?.providerId ?? providers.first.id;
  if (providers.every((provider) => provider.id != providerId)) {
    providerId = providers.first.id;
  }
  var modelOptions = textModelsForProvider(providerId);
  if (modelOptions.isEmpty) {
    await showAiSettingsDialog<void>(
      context: context,
      title: 'No Enabled Text Model',
      subtitle: 'The selected provider does not have an enabled text model.',
      width: 460,
      child: const Text('Enable at least one text model for the provider first.'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
    return null;
  }

  var modelId = existing?.modelId ?? modelOptions.first.id;
  if (modelOptions.every((model) => model.id != modelId)) {
    modelId = modelOptions.first.id;
  }

  var fallbackProviderId = existing?.fallbackProviderId ?? '';
  var fallbackModelId = existing?.fallbackModelId ?? '';
  var approvalMode = existing?.approvalMode ?? ApprovalMode.ask;
  var enabled = existing?.enabled ?? true;
  var builtinToolIds = [...(existing?.builtinToolIds ?? kBuiltinToolCatalog)];
  var skillIds = [...(existing?.skillIds ?? const <String>[])];
  var mcpServerIds = [...(existing?.mcpServerIds ?? const <String>[])];
  var subAgentIds = [...(existing?.subAgentIds ?? const <String>[])];

  final submitted = await showAiSettingsDialog<bool>(
    context: context,
    title: existing == null ? 'Add Agent' : 'Edit Agent',
    subtitle: 'Choose the provider and model pair, select allowed resources, and define fallback behavior for runtime failures.',
    width: 860,
    child: StatefulBuilder(
      builder: (context, setState) {
        final fallbackProviders = providers;
        final fallbackModels = fallbackProviderId.trim().isEmpty
            ? const <AiModelConfig>[]
            : textModelsForProvider(fallbackProviderId);

        // Build the preview from the draft form state so the button reflects
        // unsaved edits instead of the last persisted agent snapshot.
        final draftAgent = AgentConfigModel(
          id: idController.text.trim(),
          name: nameController.text.trim(),
          description: descriptionController.text.trim(),
          providerId: providerId,
          modelId: modelId,
          fallbackProviderId: fallbackProviderId,
          fallbackModelId: fallbackModelId,
          systemPrompt: systemPromptController.text,
          approvalMode: approvalMode,
          builtinToolIds: builtinToolIds,
          skillIds: skillIds,
          mcpServerIds: mcpServerIds,
          subAgentIds: subAgentIds,
          enabled: enabled,
        );

        return AiSettingsFieldGroup(
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(labelText: 'Agent ID'),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: descriptionController,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'Explain when this agent should be used.',
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                AiSettingsToggleTile(
                  title: 'Enabled',
                  subtitle: 'Controls whether the profile can be selected in Sirix CLI.',
                  value: enabled,
                  onChanged: (value) => setState(() => enabled = value),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('provider-$providerId'),
              initialValue: providerId,
              decoration: const InputDecoration(labelText: 'Primary Provider'),
              items: providers
                  .map(
                    (provider) => DropdownMenuItem(
                      value: provider.id,
                      child: Text('${provider.name} (${provider.id})'),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                final nextModelOptions = textModelsForProvider(value);
                if (nextModelOptions.isEmpty) {
                  return;
                }
                setState(() {
                  providerId = value;
                  modelOptions = nextModelOptions;
                  if (nextModelOptions.every((model) => model.id != modelId)) {
                    modelId = nextModelOptions.first.id;
                  }
                });
              },
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('model-$providerId-$modelId'),
              initialValue: modelId,
              decoration: const InputDecoration(labelText: 'Primary Model'),
              items: modelOptions
                  .map(
                    (model) => DropdownMenuItem(
                      value: model.id,
                      child: Text('${model.displayName} (${model.id})'),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() => modelId = value);
                }
              },
            ),
            DropdownButtonFormField<ApprovalMode>(
              key: ValueKey('approval-${approvalMode.name}'),
              initialValue: approvalMode,
              decoration: const InputDecoration(labelText: 'Shell Authorization'),
              items: ApprovalMode.values
                  .map(
                    (mode) => DropdownMenuItem(
                      value: mode,
                      child: Text(_approvalModeLabel(mode)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() => approvalMode = value);
                }
              },
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('fallback-provider-$fallbackProviderId'),
              initialValue: fallbackProviderId.trim().isEmpty ? '__none__' : fallbackProviderId,
              decoration: const InputDecoration(labelText: 'Fallback Provider'),
              items: [
                const DropdownMenuItem(value: '__none__', child: Text('No fallback')),
                ...fallbackProviders.map(
                  (provider) => DropdownMenuItem(
                    value: provider.id,
                    child: Text('${provider.name} (${provider.id})'),
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  if (value == null || value == '__none__') {
                    fallbackProviderId = '';
                    fallbackModelId = '';
                    return;
                  }
                  fallbackProviderId = value;
                  final nextModels = textModelsForProvider(value);
                  fallbackModelId = nextModels.isEmpty ? '' : nextModels.first.id;
                });
              },
            ),
            if (fallbackProviderId.trim().isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey('fallback-model-$fallbackProviderId-$fallbackModelId'),
                initialValue: fallbackModelId.isEmpty
                    ? (fallbackModels.isEmpty ? null : fallbackModels.first.id)
                    : fallbackModelId,
                decoration: const InputDecoration(labelText: 'Fallback Model'),
                items: fallbackModels
                    .map(
                      (model) => DropdownMenuItem(
                        value: model.id,
                        child: Text('${model.displayName} (${model.id})'),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => fallbackModelId = value);
                  }
                },
              ),
            TextField(
              controller: systemPromptController,
              minLines: 5,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Agent Prompt',
                hintText: 'Add agent-specific instructions here.',
                alignLabelWithHint: true,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _showPromptPreviewDialog(
                  context,
                  vm: vm,
                  state: state,
                  config: _buildPreviewConfigForDraft(
                    state.config,
                    existingAgentId: existing?.id,
                    draftAgent: draftAgent,
                  ),
                  agent: draftAgent,
                ),
                icon: const Icon(Icons.preview_rounded),
                label: const Text('Preview System Prompt'),
              ),
            ),
            _SelectionField(
              title: 'Builtin Tools',
              subtitle: 'New agents start with all builtin tools enabled, and you can remove any tool that should not be exposed to this agent.',
              selectionSummary: _summarizeSelection(
                selectedIds: builtinToolIds,
                allIds: kBuiltinToolCatalog,
              ),
              chips: builtinToolIds,
              onPressed: () async {
                final selected = await _showMultiSelectDialog(
                  context,
                  title: 'Builtin Tools',
                  subtitle: 'Select which builtin tools this agent can access.',
                  items: [
                    for (final id in kBuiltinToolCatalog)
                      _SelectableItem(
                        id: id,
                        label: id,
                      ),
                  ],
                  initialSelectedIds: builtinToolIds,
                );
                if (selected != null) {
                  setState(() => builtinToolIds = selected);
                }
              },
            ),
            _SelectionField(
              title: 'Skills',
              subtitle: 'Choose which configured local skills should be available to this agent.',
              selectionSummary: _summarizeSelection(
                selectedIds: skillIds,
                allIds: state.config.skills.map((item) => item.id).toList(growable: false),
              ),
              chips: [
                for (final skill in state.config.skills.where((item) => skillIds.contains(item.id)))
                  skill.name,
              ],
              onPressed: () async {
                final selected = await _showMultiSelectDialog(
                  context,
                  title: 'Skills',
                  subtitle: 'Select the local skills available to this agent.',
                  items: [
                    for (final skill in state.config.skills)
                      _SelectableItem(
                        id: skill.id,
                        label: skill.name,
                        description: skill.path,
                      ),
                  ],
                  initialSelectedIds: skillIds,
                );
                if (selected != null) {
                  setState(() => skillIds = selected);
                }
              },
            ),
            _SelectionField(
              title: 'MCP Servers',
              subtitle: 'Choose which MCP server definitions this agent can use.',
              selectionSummary: _summarizeSelection(
                selectedIds: mcpServerIds,
                allIds: state.config.mcpServers.map((item) => item.id).toList(growable: false),
              ),
              chips: [
                for (final server in state.config.mcpServers.where((item) => mcpServerIds.contains(item.id)))
                  server.name,
              ],
              onPressed: () async {
                final selected = await _showMultiSelectDialog(
                  context,
                  title: 'MCP Servers',
                  subtitle: 'Select which MCP servers this agent can access.',
                  items: [
                    for (final server in state.config.mcpServers)
                      _SelectableItem(
                        id: server.id,
                        label: server.name,
                        description: server.id,
                      ),
                  ],
                  initialSelectedIds: mcpServerIds,
                );
                if (selected != null) {
                  setState(() => mcpServerIds = selected);
                }
              },
            ),
            _SelectionField(
              title: 'Sub Agents',
              subtitle: 'Selected agents are injected into the runtime system prompt as discoverable sub-agent options.',
              selectionSummary: _summarizeSelection(
                selectedIds: subAgentIds,
                allIds: state.config.agents
                    .where((agent) => agent.id != idController.text.trim())
                    .map((item) => item.id)
                    .toList(growable: false),
              ),
              chips: [
                for (final subAgent in state.config.agents.where((item) => subAgentIds.contains(item.id)))
                  subAgent.name,
              ],
              onPressed: () async {
                final selected = await _showMultiSelectDialog(
                  context,
                  title: 'Sub Agents',
                  subtitle: 'Select the agents that should be advertised as sub-agents inside the system prompt.',
                  items: [
                    for (final subAgent in state.config.agents)
                      if (subAgent.id != idController.text.trim())
                        _SelectableItem(
                          id: subAgent.id,
                          label: subAgent.name,
                          description: subAgent.description,
                        ),
                  ],
                  initialSelectedIds: subAgentIds,
                );
                if (selected != null) {
                  setState(() => subAgentIds = selected);
                }
              },
            ),
          ],
        );
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Save'),
      ),
    ],
  );

  if (submitted != true) {
    return null;
  }

  return AgentConfigModel(
    id: idController.text.trim(),
    name: nameController.text.trim(),
    description: descriptionController.text.trim(),
    providerId: providerId,
    modelId: modelId,
    fallbackProviderId: fallbackProviderId,
    fallbackModelId: fallbackModelId,
    systemPrompt: systemPromptController.text,
    approvalMode: approvalMode,
    builtinToolIds: builtinToolIds,
    skillIds: skillIds,
    mcpServerIds: mcpServerIds,
    subAgentIds: subAgentIds,
    enabled: enabled,
  );
}

class _SelectionField extends StatelessWidget {
  const _SelectionField({
    required this.title,
    required this.subtitle,
    required this.selectionSummary,
    required this.chips,
    required this.onPressed,
  });

  final String title;
  final String subtitle;
  final String selectionSummary;
  final List<String> chips;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return AiSettingsCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.textMuted,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Select'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            selectionSummary,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips.isEmpty
                ? [AiSettingsChip(label: 'None selected')]
                : chips.map((label) => AiSettingsChip(label: label)).toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class _SelectableItem {
  const _SelectableItem({
    required this.id,
    required this.label,
    this.description,
  });

  final String id;
  final String label;
  final String? description;
}

Future<List<String>?> _showMultiSelectDialog(
  BuildContext context, {
  required String title,
  required String subtitle,
  required List<_SelectableItem> items,
  required List<String> initialSelectedIds,
}) async {
  final selected = initialSelectedIds.toSet();

  return showAiSettingsDialog<List<String>>(
    context: context,
    title: title,
    subtitle: subtitle,
    width: 680,
    child: StatefulBuilder(
      builder: (context, setState) {
        return Column(
          children: [
            for (final item in items)
              CheckboxListTile(
                value: selected.contains(item.id),
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      selected.add(item.id);
                    } else {
                      selected.remove(item.id);
                    }
                  });
                },
                title: Text(item.label),
                subtitle: item.description == null || item.description!.trim().isEmpty
                    ? null
                    : Text(item.description!),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
          ],
        );
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(selected.toList(growable: false)),
        child: const Text('Apply'),
      ),
    ],
  );
}

Future<void> _showPromptPreviewDialog(
  BuildContext context,
  {
  required AiSettingsViewModel vm,
  required AiSettingsState state,
  required SirixAiConfig config,
  required AgentConfigModel agent,
}) {
  final palette = context.sirix;
  final previewFuture = vm.previewSystemPrompt(
    config: config,
    agentId: agent.id,
    cwd: state.effective?.workspacePath,
  );

  return showAiSettingsDialog<void>(
    context: context,
    title: 'System Prompt Preview',
    subtitle:
        'This preview expands the selected agent into the composed system prompt, including discovered MCP tools, schemas, skills, and sub-agents.',
    width: 900,
    child: FutureBuilder<String>(
      future: previewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 240,
            child: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          return SelectableText(
            'Failed to generate prompt preview: ${snapshot.error}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontFamily: 'JetBrains Mono',
                  height: 1.6,
                  color: palette.textSecondary,
                ),
          );
        }

        final preview = (snapshot.data ?? '').trim();
        return SelectableText(
          preview.isEmpty ? 'No system prompt content generated.' : preview,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: 'JetBrains Mono',
                height: 1.6,
                color: palette.textSecondary,
              ),
        );
      },
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}

SirixAiConfig _buildPreviewConfigForDraft(
  SirixAiConfig config, {
  required String? existingAgentId,
  required AgentConfigModel draftAgent,
}) {
  final agents = [...config.agents];
  final replaceIndex = agents.indexWhere(
    (item) => item.id == (existingAgentId ?? draftAgent.id),
  );
  if (replaceIndex >= 0) {
    agents[replaceIndex] = draftAgent;
  } else {
    final duplicateIndex = agents.indexWhere((item) => item.id == draftAgent.id);
    if (duplicateIndex >= 0) {
      agents[duplicateIndex] = draftAgent;
    } else {
      agents.add(draftAgent);
    }
  }
  return config.copyWith(agents: agents);
}

String _summarizeSelection({
  required List<String> selectedIds,
  required List<String> allIds,
}) {
  if (allIds.isEmpty) {
    return 'No options available.';
  }
  if (selectedIds.isEmpty) {
    return 'Nothing selected.';
  }
  if (selectedIds.length == allIds.length) {
    return 'All ${allIds.length} selected.';
  }
  return '${selectedIds.length} of ${allIds.length} selected.';
}

String _approvalModeLabel(ApprovalMode mode) {
  return switch (mode) {
    ApprovalMode.allow => 'Allow',
    ApprovalMode.ask => 'Ask',
    ApprovalMode.deny => 'Deny',
  };
}
