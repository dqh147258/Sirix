import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../ai_settings_view_model.dart';
import '../settings_ui.dart';

const String _builtinCodexAgentId = 'codex';

bool _isBuiltinCodexAgent(AgentConfigModel agent) => agent.id == _builtinCodexAgentId;

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
  // Desktop split panes render two independent vertical scroll areas side by
  // side. The agent rail must keep a dedicated controller so the Scrollbar and
  // ListView share the same ScrollPosition instead of falling back to the
  // route-level PrimaryScrollController, which is what triggers the framework
  // assertion reported by the user.
  final ScrollController _agentListScrollController = ScrollController();
  String? _selectedAgentId;

  @override
  void initState() {
    super.initState();
    if (widget.state.visibleAgents.isNotEmpty) {
      _selectedAgentId = widget.state.visibleAgents.first.id;
    }
  }

  @override
  void dispose() {
    _agentListScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AgentSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedAgentId != null &&
        !widget.state.visibleAgents.any((agent) => agent.id == _selectedAgentId)) {
      _selectedAgentId = null;
    }
    if (_selectedAgentId == null && widget.state.visibleAgents.isNotEmpty) {
      _selectedAgentId = widget.state.visibleAgents.first.id;
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
          scrollController: _agentListScrollController,
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
            widget.vm.upsertAgent(created.agent);
            setState(() => _selectedAgentId = created.agent.id);
          },
        );

        final visibleAgents = widget.state.visibleAgents;
        final selectedAgent = _selectedAgentId == null
            ? null
            : visibleAgents.firstWhere(
                (agent) => agent.id == _selectedAgentId,
              );
        final detailPane = selectedAgent == null
            ? const AiSettingsEmptyState(text: 'Select an agent or create a new profile.')
            : _AgentDetailPane(
                agent: selectedAgent,
                state: widget.state,
                vm: widget.vm,
                sourceLabel: widget.state.sourceLabelForResource(
                  workspaceOwned: widget.state.workspaceOwnsAgent(selectedAgent.id),
                  globalOwned: widget.state.globalOwnsAgent(selectedAgent.id),
                ),
                onEdit: () async {
                  final updated = await _showAgentDialog(
                    context,
                    state: widget.state,
                    vm: widget.vm,
                    existing: selectedAgent,
                  );
                  if (updated != null) {
                    widget.vm.upsertAgent(updated.agent);
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
    required this.scrollController,
    required this.onSelect,
    required this.onCreate,
  });

  final AiSettingsState state;
  final String? selectedAgentId;
  final bool compact;
  final ScrollController scrollController;
  final ValueChanged<String> onSelect;
  final Future<void> Function() onCreate;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final visibleAgents = state.visibleAgents;
    final agentCards = [
      for (final agent in visibleAgents) _AgentListItem(
        agent: agent,
        selected: agent.id == selectedAgentId,
        compact: compact,
        sourceLabel: state.sourceLabelForResource(
          workspaceOwned: state.workspaceOwnsAgent(agent.id),
          globalOwned: state.globalOwnsAgent(agent.id),
        ),
        onTap: () => onSelect(agent.id),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasBoundedHeight = constraints.hasBoundedHeight;
        final listView = ListView.separated(
          controller: scrollController,
          padding: EdgeInsets.zero,
          // This pane sits next to another vertical scroll view in the desktop
          // split layout. Mark it as non-primary so it does not try to reuse
          // the route-level PrimaryScrollController and collide with the
          // detail pane's own ListView at runtime.
          primary: false,
          shrinkWrap: !hasBoundedHeight,
          physics: hasBoundedHeight
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          itemCount: agentCards.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) => agentCards[index],
        );

        return AiSettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  SizedBox(
                    width: compact ? 180 : 210,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Agent Profiles',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontFamily: 'Space Grotesk',
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Manage runtime profiles, approvals, and fallback behavior without breaking the split-pane layout.',
                          maxLines: compact ? 4 : 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: palette.textMuted,
                              ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('New Agent'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (visibleAgents.isEmpty)
                const AiSettingsEmptyState(text: 'No agents configured yet.')
              else if (hasBoundedHeight)
                Expanded(
                  // The left agent rail now owns its own scrollable viewport so
                  // long profile lists stay usable inside the fixed desktop
                  // split-pane layout instead of overflowing the card.
                  child: Scrollbar(
                    controller: scrollController,
                    thumbVisibility: true,
                    child: listView,
                  ),
                )
              else
                listView,
            ],
          ),
        );
      },
    );
  }
}

class _AgentListItem extends StatelessWidget {
  const _AgentListItem({
    required this.agent,
    required this.selected,
    required this.compact,
    required this.sourceLabel,
    required this.onTap,
  });

  final AgentConfigModel agent;
  final bool selected;
  final bool compact;
  final String? sourceLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.all(compact ? 12 : 14),
          decoration: BoxDecoration(
            color: selected ? palette.surfaceMuted.withValues(alpha: 0.52) : palette.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? palette.primaryBright.withValues(alpha: 0.4)
                  : palette.glassStroke,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: compact ? 30 : 34,
                height: compact ? 30 : 34,
                decoration: BoxDecoration(
                  color: agent.enabled
                      ? palette.primaryBright.withValues(alpha: 0.16)
                      : palette.surfaceMuted,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.smart_toy_rounded,
                  size: compact ? 16 : 18,
                  color: agent.enabled ? palette.primaryBright : palette.textMuted,
                ),
              ),
              const SizedBox(width: 10),
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
                            fontSize: compact ? 14 : null,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      agent.description.trim().isEmpty ? agent.id : agent.description,
                      maxLines: compact ? 2 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.textMuted,
                            height: compact ? 1.35 : 1.45,
                          ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (sourceLabel != null && sourceLabel!.trim().isNotEmpty)
                          AiSettingsChip(label: sourceLabel!),
                        AiSettingsChip(label: agent.providerId),
                        AiSettingsChip(label: agent.modelId),
                        AiSettingsChip(label: agent.enabled ? 'Enabled' : 'Disabled'),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentDetailPane extends StatelessWidget {
  const _AgentDetailPane({
    required this.agent,
    required this.state,
    required this.vm,
    required this.sourceLabel,
    required this.onEdit,
  });

  final AgentConfigModel agent;
  final AiSettingsState state;
  final AiSettingsViewModel vm;
  final String? sourceLabel;
  final Future<void> Function() onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final isBuiltinCodex = _isBuiltinCodexAgent(agent);
    final canRemoveAgent =
        !isBuiltinCodex && (!state.isWorkspaceScope || state.workspaceOwnsAgent(agent.id));
    final skills = state.visibleSkills.where((item) => agent.skillIds.contains(item.id)).toList();
    final mcpServers =
        state.visibleMcpServers.where((item) => agent.mcpServerIds.contains(item.id)).toList();
    final subAgents = state.visibleAgents
        .where((item) => agent.subAgentIds.contains(item.id))
        .toList(growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasBoundedHeight = constraints.hasBoundedHeight;

        return ListView(
          padding: const EdgeInsets.only(bottom: 8),
          // This detail pane is rendered both inside the desktop split view and
          // inside the narrow stacked mobile-style layout. In the stacked case
          // the parent already owns the vertical scrollable, so this inner
          // ListView must shrink-wrap and disable its own scrolling to avoid
          // creating an unbounded nested viewport.
          primary: false,
          shrinkWrap: !hasBoundedHeight,
          physics: hasBoundedHeight
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
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
                                if (sourceLabel != null && sourceLabel!.trim().isNotEmpty)
                                  AiSettingsChip(label: sourceLabel!),
                                AiSettingsChip(label: agent.providerId),
                                AiSettingsChip(label: agent.modelId),
                                AiSettingsChip(label: approvalModeLabel(agent.approvalMode)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Switch(
                        value: agent.enabled,
                        onChanged: isBuiltinCodex
                            ? null
                            : (value) => vm.upsertAgent(agent.copyWith(enabled: value)),
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
                          config: state.promptPreviewBaseConfig,
                          agent: agent,
                        ),
                        icon: const Icon(Icons.preview_rounded),
                        label: const Text('Preview System Prompt'),
                      ),
                      OutlinedButton.icon(
                        onPressed: canRemoveAgent ? () => vm.removeAgent(agent.id) : null,
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
                        'Built-in Profile',
                        isBuiltinCodex
                            ? 'Uses the standard Codex system prompt and the full builtin tool set. Only MCP, skills, provider/model, and sub-agents are configurable here.'
                            : 'No',
                      ),
                      (
                        'Fallback',
                        agent.fallbackProviderId.trim().isEmpty ||
                                agent.fallbackModelId.trim().isEmpty
                            ? 'Not configured'
                            : '${agent.fallbackProviderId} / ${agent.fallbackModelId}',
                      ),
                      ('Shell Authorization', approvalModeLabel(agent.approvalMode)),
                      ('Agent Shell Rules', _shellRulesSummary(agent.shellRules)),
                    ],
                  ),
                );
                final accessCard = AiSettingsCard(
                  child: _InfoList(
                    rows: [
                      ('Builtin Tools', '${agent.builtinToolIds.length} selected'),
                      (
                        'Skills',
                        skills.isEmpty ? 'None selected' : skills.map((item) => item.name).join(', '),
                      ),
                      (
                        'MCP Servers',
                        mcpServers.isEmpty
                            ? 'None selected'
                            : mcpServers.map((item) => item.name).join(', '),
                      ),
                      (
                        'Sub Agents',
                        subAgents.isEmpty
                            ? 'None selected'
                            : subAgents.map((item) => item.name).join(', '),
                      ),
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
                    isBuiltinCodex ? 'Built-in System Prompt' : 'Custom System Prompt',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isBuiltinCodex
                        ? 'This profile always uses the standard Codex system prompt. Desktop Server only adds the shared CLI supplemental prompt plus the agent-specific MCP, skills, and sub-agent runtime config.'
                        : agent.systemPrompt.trim().isEmpty
                            ? 'No additional system prompt has been configured for this agent.'
                            : agent.systemPrompt,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: (isBuiltinCodex || agent.systemPrompt.trim().isEmpty)
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
      },
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

class _AgentDialogResult {
  const _AgentDialogResult({
    required this.agent,
  });

  final AgentConfigModel agent;
}

Future<_AgentDialogResult?> _showAgentDialog(
  BuildContext context, {
  required AiSettingsState state,
  required AiSettingsViewModel vm,
  required AgentConfigModel? existing,
}) async {
  // Workspace Settings keeps provider/model definitions global-only, so the
  // agent editor always reads picker options from the effective provider
  // catalog while the saved agent object itself still remains workspace-local.
  final providers = state.agentPickerProviders
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

  final globalConfig = state.globalReferenceConfig;
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
  final isBuiltinCodex = existing != null && _isBuiltinCodexAgent(existing);

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
  if (fallbackProviderId.trim().isNotEmpty &&
      providers.every((provider) => provider.id != fallbackProviderId)) {
    // Workspace/global agent overrides can outlive provider list changes. If a
    // previously saved fallback provider is now disabled or removed, clear the
    // stale fallback locally so opening the dialog never crashes before the
    // user has a chance to repair the agent configuration.
    fallbackProviderId = '';
    fallbackModelId = '';
  }
  if (fallbackProviderId.trim().isNotEmpty) {
    final fallbackModels = textModelsForProvider(fallbackProviderId);
    if (fallbackModels.isEmpty || fallbackModels.every((model) => model.id != fallbackModelId)) {
      // A fallback model can disappear independently of its provider (for
      // example the provider stays enabled but the old text model is disabled).
      // Coerce the stale selection up front so the dropdown never receives an
      // invalid initial value that would break dialog rendering.
      fallbackModelId = fallbackModels.isEmpty ? '' : fallbackModels.first.id;
    }
  }
  var approvalMode = existing?.approvalMode ?? ApprovalMode.ask;
  var shellRules = existing?.shellRules ?? const ShellRulesConfigModel();
  final builtinApprovalBase = globalConfig.builtinApprovals;
  final skillApprovalBase = globalConfig.skillApprovals;
  final mcpApprovalBase = globalConfig.mcpApprovals;
  final workspaceBuiltinApprovals = state.config.builtinApprovals;
  final workspaceSkillApprovals = state.config.skillApprovals;
  final workspaceMcpApprovals = state.config.mcpApprovals;
  // Agent-specific capability editors should work from the inherited global
  // layer first, then save back only the delta. Workspace approval policy is
  // intentionally rendered separately as a read-only layer because the runtime
  // applies workspace policy after agent overrides.
  var builtinApprovals = mergeCapabilityRules(
    builtinApprovalBase,
    existing?.builtinApprovals ?? const CapabilityRulesConfigModel(),
  );
  var skillApprovals = mergeCapabilityRules(
    skillApprovalBase,
    existing?.skillApprovals ?? const CapabilityRulesConfigModel(),
  );
  var mcpApprovals = mergeCapabilityRules(
    mcpApprovalBase,
    existing?.mcpApprovals ?? const CapabilityRulesConfigModel(),
  );
  var enabled = existing?.enabled ?? true;
  var builtinToolIds = [...(existing?.builtinToolIds ?? kBuiltinToolCatalog)];
  var skillIds = [...(existing?.skillIds ?? const <String>[])];
  var mcpServerIds = [...(existing?.mcpServerIds ?? const <String>[])];
  var subAgentIds = [...(existing?.subAgentIds ?? const <String>[])];
  final allowRulesController = TextEditingController(text: shellRules.allow.join('\n'));
  final denyRulesController = TextEditingController(text: shellRules.deny.join('\n'));
  final discoveredMcpServers = {
    for (final server in state.statusOverview?.mcp.servers ?? const <LocalMcpServerStatus>[])
      server.id: server,
  };

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
        final availableSkills = state.visibleSkills;
        final availableMcpServers = state.visibleMcpServers;
        final availableSubAgents = state.visibleAgents
            .where((agent) => agent.id != idController.text.trim())
            .toList(growable: false);

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
          shellRules: shellRules,
          builtinApprovals: diffCapabilityRulesOverlay(
            builtinApprovalBase,
            builtinApprovals,
          ),
          skillApprovals: diffCapabilityRulesOverlay(
            skillApprovalBase,
            skillApprovals,
          ),
          mcpApprovals: diffCapabilityRulesOverlay(
            mcpApprovalBase,
            mcpApprovals,
          ),
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
              readOnly: isBuiltinCodex,
              decoration: InputDecoration(
                labelText: 'Agent ID',
                helperText: isBuiltinCodex
                    ? 'The built-in Codex profile keeps a fixed runtime id.'
                    : null,
              ),
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
                  subtitle: isBuiltinCodex
                      ? 'The built-in Codex profile always stays enabled so Sirix keeps a stable default agent.'
                      : 'Controls whether the profile can be selected in Sirix CLI.',
                  value: enabled,
                  onChanged: isBuiltinCodex
                      ? null
                      : (value) => setState(() => enabled = value),
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Shell Authorization',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: context.sirix.textMuted,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 10),
                ApprovalModeSegmentedControl(
                  value: approvalMode,
                  onChanged: (value) {
                    setState(() => approvalMode = value);
                  },
                ),
              ],
            ),
            AiSettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Agent Shell Rules',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'These allow and deny prefixes are merged on top of the global and workspace shell rules. If the same prefix conflicts, the agent definition wins. Temporary runtime decisions can still override both for the current session.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.sirix.textMuted,
                        ),
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final stacked = constraints.maxWidth < 720;
                      final allowEditor = _AgentRuleEditor(
                        title: 'Allow Prefixes',
                        subtitle: 'Use allow entries when this agent should skip prompts for a known-safe command family.',
                        hintText: 'git status\ngit diff',
                        controller: allowRulesController,
                        accentColor: context.sirix.primaryBright,
                        onChanged: (value) {
                          setState(() {
                            shellRules = shellRules.copyWith(
                              allow: _parseShellRuleLines(value),
                            );
                          });
                        },
                      );
                      final denyEditor = _AgentRuleEditor(
                        title: 'Deny Prefixes',
                        subtitle: 'Use deny entries when this agent must never run a prefix even if it is globally allowed.',
                        hintText: 'rm -rf\nsudo rm',
                        controller: denyRulesController,
                        accentColor: context.sirix.error,
                        onChanged: (value) {
                          setState(() {
                            shellRules = shellRules.copyWith(
                              deny: _parseShellRuleLines(value),
                            );
                          });
                        },
                      );

                      if (stacked) {
                        return Column(
                          children: [
                            allowEditor,
                            const SizedBox(height: 12),
                            denyEditor,
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: allowEditor),
                          const SizedBox(width: 12),
                          Expanded(child: denyEditor),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            _AgentCapabilityOverridesCard(
              title: 'Builtin Tool Permissions',
              subtitle: state.isWorkspaceScope
                  ? 'Adjust the global-derived builtin permission layer for this agent. Workspace policy is shown below as read-only because workspace permission edits stay on the Permissions page.'
                  : 'Override the global builtin permission defaults for this agent. These entries apply after the global layer and before workspace/session decisions.',
              config: builtinApprovals,
              referenceConfig: state.isWorkspaceScope ? builtinApprovalBase : null,
              items: [
                for (final id in builtinToolIds)
                  _SelectableItem(
                    id: 'builtin.$id',
                    label: id,
                    referenceMode: capabilityRuleModeFor(
                      builtinApprovalBase,
                      'builtin.$id',
                    ),
                  ),
              ],
              lockedConfig: state.isWorkspaceScope ? workspaceBuiltinApprovals : null,
              lockedItems: state.isWorkspaceScope
                  ? [
                      for (final id in builtinToolIds)
                        _SelectableItem(
                          id: 'builtin.$id',
                          label: id,
                          sourceLabel: 'Workspace',
                        ),
                    ]
                  : const [],
              onLockedInteraction: state.isWorkspaceScope
                  ? () => _showWorkspacePermissionEditHint(context)
                  : null,
              onChanged: (next) => setState(() => builtinApprovals = next),
            ),
            _AgentCapabilityOverridesCard(
              title: 'Skill Permissions',
              subtitle: state.isWorkspaceScope
                  ? 'Adjust the global-derived skill permission layer for this agent. Workspace skill policy is visible below as read-only.'
                  : 'Override the global skill permission defaults for this agent.',
              config: skillApprovals,
              referenceConfig: state.isWorkspaceScope ? skillApprovalBase : null,
              items: [
                for (final skill in availableSkills.where((item) => skillIds.contains(item.id)))
                  _SelectableItem(
                    id: 'skill.${skill.id}',
                    label: skill.name,
                    description: skill.path,
                    referenceMode: capabilityRuleModeFor(
                      skillApprovalBase,
                      'skill.${skill.id}',
                    ),
                  ),
              ],
              lockedConfig: state.isWorkspaceScope ? workspaceSkillApprovals : null,
              lockedItems: state.isWorkspaceScope
                  ? [
                      for (final skill in availableSkills.where((item) => skillIds.contains(item.id)))
                        _SelectableItem(
                          id: 'skill.${skill.id}',
                          label: skill.name,
                          description: skill.path,
                          sourceLabel: 'Workspace',
                        ),
                    ]
                  : const [],
              onLockedInteraction: state.isWorkspaceScope
                  ? () => _showWorkspacePermissionEditHint(context)
                  : null,
              onChanged: (next) => setState(() => skillApprovals = next),
            ),
            _AgentCapabilityOverridesCard(
              title: 'MCP Permissions',
              subtitle: state.isWorkspaceScope
                  ? 'Adjust the global-derived MCP permission layer for this agent. Workspace MCP policy is visible below as read-only.'
                  : 'Override the global MCP permission defaults for this agent at the server/function level using Desktop Server discovery results.',
              config: mcpApprovals,
              referenceConfig: state.isWorkspaceScope ? mcpApprovalBase : null,
              items: [
                for (final server in availableMcpServers.where((item) => mcpServerIds.contains(item.id))) ...[
                  _SelectableItem(
                    id: 'mcp.${server.id}',
                    label: server.name,
                    description: server.id,
                    referenceMode: capabilityRuleModeFor(
                      mcpApprovalBase,
                      'mcp.${server.id}',
                    ),
                  ),
                  for (final tool in discoveredMcpServers[server.id]?.discoveredTools ?? const <LocalMcpServerToolStatus>[])
                    _SelectableItem(
                      id: 'mcp.${server.id}.${tool.id}',
                      label: '${server.name} · ${tool.title}',
                      description: tool.description ?? tool.id,
                      referenceMode: capabilityRuleModeFor(
                        mcpApprovalBase,
                        'mcp.${server.id}.${tool.id}',
                      ),
                    ),
                ],
              ],
              lockedConfig: state.isWorkspaceScope ? workspaceMcpApprovals : null,
              lockedItems: state.isWorkspaceScope
                  ? [
                      for (final server in availableMcpServers.where((item) => mcpServerIds.contains(item.id))) ...[
                        _SelectableItem(
                          id: 'mcp.${server.id}',
                          label: server.name,
                          description: server.id,
                          sourceLabel: 'Workspace',
                        ),
                        for (final tool in discoveredMcpServers[server.id]?.discoveredTools ?? const <LocalMcpServerToolStatus>[])
                          _SelectableItem(
                            id: 'mcp.${server.id}.${tool.id}',
                            label: '${server.name} · ${tool.title}',
                            description: tool.description ?? tool.id,
                            sourceLabel: 'Workspace',
                          ),
                      ],
                    ]
                  : const [],
              onLockedInteraction: state.isWorkspaceScope
                  ? () => _showWorkspacePermissionEditHint(context)
                  : null,
              onChanged: (next) => setState(() => mcpApprovals = next),
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
              readOnly: isBuiltinCodex,
              minLines: 5,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: 'Agent Prompt',
                hintText: isBuiltinCodex
                    ? 'The built-in Codex profile always uses the standard Codex system prompt.'
                    : 'Add agent-specific instructions here.',
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
                    state.promptPreviewBaseConfig,
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
              subtitle: isBuiltinCodex
                  ? 'The built-in Codex profile always exposes the full builtin Codex tool set.'
                  : 'New agents start with all builtin tools enabled, and you can remove any tool that should not be exposed to this agent.',
              selectionSummary: _summarizeSelection(
                selectedIds: builtinToolIds,
                allIds: kBuiltinToolCatalog,
              ),
              chips: builtinToolIds,
              enabled: !isBuiltinCodex,
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
              subtitle: state.isWorkspaceScope
                  ? 'Choose which workspace skills should be available to this agent.'
                  : 'Choose which configured local skills should be available to this agent.',
              selectionSummary: _summarizeSelection(
                selectedIds: skillIds,
                allIds: availableSkills.map((item) => item.id).toList(growable: false),
              ),
              chips: [
                for (final skill in availableSkills.where((item) => skillIds.contains(item.id)))
                  skill.name,
              ],
              onPressed: () async {
                final selected = await _showMultiSelectDialog(
                  context,
                  title: 'Skills',
                  subtitle: 'Select the local skills available to this agent.',
                  items: [
                    for (final skill in availableSkills)
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
              subtitle: state.isWorkspaceScope
                  ? 'Choose which workspace MCP server definitions this agent can use.'
                  : 'Choose which MCP server definitions this agent can use.',
              selectionSummary: _summarizeSelection(
                selectedIds: mcpServerIds,
                allIds: availableMcpServers.map((item) => item.id).toList(growable: false),
              ),
              chips: [
                for (final server in availableMcpServers.where((item) => mcpServerIds.contains(item.id)))
                  server.name,
              ],
              onPressed: () async {
                final selected = await _showMultiSelectDialog(
                  context,
                  title: 'MCP Servers',
                  subtitle: 'Select which MCP servers this agent can access.',
                  items: [
                    for (final server in availableMcpServers)
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
              subtitle: state.isWorkspaceScope
                  ? 'Selected workspace agents are exposed to Codex as spawnable Sirix sub-agent roles.'
                  : 'Selected agents are exposed to Codex as spawnable Sirix sub-agent roles with role descriptions and runtime role configs.',
              selectionSummary: _summarizeSelection(
                selectedIds: subAgentIds,
                allIds: availableSubAgents.map((item) => item.id).toList(growable: false),
              ),
              chips: [
                for (final subAgent in availableSubAgents.where((item) => subAgentIds.contains(item.id)))
                  subAgent.name,
              ],
              onPressed: () async {
                final selected = await _showMultiSelectDialog(
                  context,
                  title: 'Sub Agents',
                  subtitle: 'Select the agents that should be exposed as Sirix sub-agent roles for this profile.',
                  items: [
                    for (final subAgent in availableSubAgents)
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

  return _AgentDialogResult(
    agent: AgentConfigModel(
      id: isBuiltinCodex ? _builtinCodexAgentId : idController.text.trim(),
      name: nameController.text.trim(),
      description: descriptionController.text.trim(),
      providerId: providerId,
      modelId: modelId,
      fallbackProviderId: fallbackProviderId,
      fallbackModelId: fallbackModelId,
      systemPrompt: isBuiltinCodex ? '' : systemPromptController.text,
      approvalMode: approvalMode,
      shellRules: shellRules,
      builtinApprovals: diffCapabilityRulesOverlay(
        builtinApprovalBase,
        builtinApprovals,
      ),
      skillApprovals: diffCapabilityRulesOverlay(
        skillApprovalBase,
        skillApprovals,
      ),
      mcpApprovals: diffCapabilityRulesOverlay(
        mcpApprovalBase,
        mcpApprovals,
      ),
      builtinToolIds: isBuiltinCodex ? kBuiltinToolCatalog : builtinToolIds,
      skillIds: skillIds,
      mcpServerIds: mcpServerIds,
      subAgentIds: subAgentIds,
      enabled: isBuiltinCodex ? true : enabled,
    ),
  );
}

class _AgentRuleEditor extends StatelessWidget {
  const _AgentRuleEditor({
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceMuted,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.glassStroke),
      ),
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
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
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
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            minLines: 7,
            maxLines: 10,
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

class _AgentCapabilityOverridesCard extends StatelessWidget {
  const _AgentCapabilityOverridesCard({
    required this.title,
    required this.subtitle,
    required this.config,
    required this.items,
    required this.onChanged,
    this.referenceConfig,
    this.lockedConfig,
    this.lockedItems = const [],
    this.onLockedInteraction,
  });

  final String title;
  final String subtitle;
  final CapabilityRulesConfigModel config;
  final List<_SelectableItem> items;
  final ValueChanged<CapabilityRulesConfigModel> onChanged;
  final CapabilityRulesConfigModel? referenceConfig;
  final CapabilityRulesConfigModel? lockedConfig;
  final List<_SelectableItem> lockedItems;
  final VoidCallback? onLockedInteraction;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return AiSettingsCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                ),
          ),
          const SizedBox(height: 16),
          Text(
            'Default Mode',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: palette.textMuted,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 10),
          ApprovalModeSegmentedControl(
            value: config.mode,
            referenceMode: referenceConfig?.mode,
            onChanged: (value) {
              onChanged(config.copyWith(mode: value));
            },
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final item in items) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 760;
                  final details = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.label,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      if (item.description != null && item.description!.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            item.description!,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: palette.textMuted,
                                ),
                          ),
                        ),
                    ],
                  );
                  final control = SizedBox(
                    width: stacked ? double.infinity : 240,
                    child: ApprovalModeSegmentedControl(
                      value: _agentCapabilityModeFor(config, item.id),
                      referenceMode: item.referenceMode,
                      dense: true,
                      onChanged: (value) {
                        onChanged(_agentCapabilityConfigWithRule(config, item.id, value));
                      },
                    ),
                  );

                  if (stacked) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        details,
                        const SizedBox(height: 12),
                        control,
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: details),
                      const SizedBox(width: 12),
                      control,
                    ],
                  );
                },
              ),
              if (item != items.last) const Divider(height: 18),
            ],
          ],
          if (lockedConfig != null) ...[
            const SizedBox(height: 18),
            Divider(color: palette.glassStroke),
            const SizedBox(height: 18),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onLockedInteraction,
              child: AbsorbPointer(
                child: Opacity(
                  opacity: 0.7,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Workspace Layer',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const AiSettingsChip(label: 'Workspace'),
                          const Icon(Icons.lock_outline_rounded, size: 16),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Workspace policy is applied after agent overrides. Edit these values on the Permissions page.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                            ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Default Mode',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: palette.textMuted,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 10),
                      ApprovalModeSegmentedControl(
                        value: lockedConfig!.mode,
                        onChanged: (_) {},
                      ),
                      if (lockedItems.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        for (final item in lockedItems) ...[
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final stacked = constraints.maxWidth < 760;
                              final details = Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        item.label,
                                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      if (item.sourceLabel != null &&
                                          item.sourceLabel!.trim().isNotEmpty)
                                        AiSettingsChip(label: item.sourceLabel!),
                                    ],
                                  ),
                                  if (item.description != null &&
                                      item.description!.trim().isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        item.description!,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: palette.textMuted,
                                            ),
                                      ),
                                    ),
                                ],
                              );
                              final control = SizedBox(
                                width: stacked ? double.infinity : 240,
                                child: ApprovalModeSegmentedControl(
                                  value: _agentCapabilityModeFor(lockedConfig!, item.id),
                                  dense: true,
                                  onChanged: (_) {},
                                ),
                              );

                              if (stacked) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    details,
                                    const SizedBox(height: 12),
                                    control,
                                  ],
                                );
                              }

                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: details),
                                  const SizedBox(width: 12),
                                  control,
                                ],
                              );
                            },
                          ),
                          if (item != lockedItems.last) const Divider(height: 18),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

ApprovalMode _agentCapabilityModeFor(CapabilityRulesConfigModel config, String key) {
  return capabilityRuleModeFor(config, key);
}

CapabilityRulesConfigModel _agentCapabilityConfigWithRule(
  CapabilityRulesConfigModel config,
  String key,
  ApprovalMode mode,
) {
  final normalizedKey = normalizeCapabilityRuleKey(key);
  final nextRules = [
    for (final rule in config.rules)
      if (normalizeCapabilityRuleKey(rule.key) != normalizedKey) rule,
    CapabilityApprovalRuleModel(key: normalizedKey, mode: mode),
  ];
  return config.copyWith(rules: nextRules);
}

void _showWorkspacePermissionEditHint(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Workspace permission policy is read-only here. Open Permissions to change it.'),
    ),
  );
}

class _SelectionField extends StatelessWidget {
  const _SelectionField({
    required this.title,
    required this.subtitle,
    required this.selectionSummary,
    required this.chips,
    required this.onPressed,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final String selectionSummary;
  final List<String> chips;
  final VoidCallback onPressed;
  final bool enabled;

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
                onPressed: enabled ? onPressed : null,
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
    this.sourceLabel,
    this.referenceMode,
  });

  final String id;
  final String label;
  final String? description;
  final String? sourceLabel;
  final ApprovalMode? referenceMode;
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
                secondary: item.sourceLabel == null || item.sourceLabel!.trim().isEmpty
                    ? null
                    : AiSettingsChip(label: item.sourceLabel!),
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
    cwd: state.isWorkspaceScope ? state.selectedWorkspaceRoot : state.effective?.workspacePath,
  );

  return showAiSettingsDialog<void>(
    context: context,
    title: 'System Prompt Preview',
    subtitle:
        'This preview shows the actual Responses request body generated through the embedded Codex runtime for the selected agent. Conversation turns are omitted so you can focus on instructions, context blocks, skills, and tool schemas.',
    width: 1040,
    child: FutureBuilder<Object?>(
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
          return SingleChildScrollView(
            child: SelectableText(
              'Failed to generate prompt preview: ${snapshot.error}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFamily: 'JetBrains Mono',
                    height: 1.6,
                    color: palette.textSecondary,
                  ),
            ),
          );
        }

        final preview = snapshot.data;
        if (preview == null) {
          return Text(
            'No preview data generated.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: palette.textSecondary,
                ),
          );
        }

        return _PromptPreviewContent(preview: preview);
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

List<String> _parseShellRuleLines(String raw) {
  return raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
}

String _shellRulesSummary(ShellRulesConfigModel shellRules) {
  final allowCount = shellRules.allow.length;
  final denyCount = shellRules.deny.length;
  if (allowCount == 0 && denyCount == 0) {
    return 'No agent-specific overrides.';
  }
  return 'Allow $allowCount, Deny $denyCount';
}

enum _PromptPreviewMode {
  readable,
  rawJson,
}

class _PromptPreviewContent extends StatefulWidget {
  const _PromptPreviewContent({
    required this.preview,
  });

  final Object? preview;

  @override
  State<_PromptPreviewContent> createState() => _PromptPreviewContentState();
}

class _PromptPreviewContentState extends State<_PromptPreviewContent> {
  _PromptPreviewMode _mode = _PromptPreviewMode.readable;

  @override
  Widget build(BuildContext context) {
    final previewMap = _normalizePreviewMap(widget.preview);
    final instructions = _readNonEmptyString(previewMap['instructions']);
    final inputBlocks = _extractPreviewInputBlocks(previewMap);
    final tools = _extractPreviewTools(previewMap);
    final rawJson = _prettyPreviewJson(widget.preview);
    final model = _readNonEmptyString(previewMap['model']);
    final toolChoice = _readNonEmptyString(previewMap['tool_choice']);
    final stream = previewMap['stream'];
    final parallelCalls = previewMap['parallel_tool_calls'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The user asked for two complementary ways to inspect the same preview:
        // a readable UI for prompt/tool review and the original JSON for exact
        // payload verification.
        _PromptPreviewModeSwitcher(
          mode: _mode,
          onChanged: (mode) => setState(() => _mode = mode),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (model != null) AiSettingsChip(label: 'model: $model'),
            AiSettingsChip(label: 'input blocks: ${inputBlocks.length}'),
            AiSettingsChip(label: 'tools: ${tools.length}'),
            if (toolChoice != null) AiSettingsChip(label: 'tool_choice: $toolChoice'),
            if (stream is bool) AiSettingsChip(label: 'stream: ${stream ? 'on' : 'off'}'),
            if (parallelCalls is bool)
              AiSettingsChip(
                label: 'parallel: ${parallelCalls ? 'enabled' : 'disabled'}',
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (_mode == _PromptPreviewMode.readable)
          _PromptPreviewReadableView(
            instructions: instructions,
            inputBlocks: inputBlocks,
            tools: tools,
            previewMap: previewMap,
          )
        else
          _PromptPreviewRawJsonView(rawJson: rawJson),
      ],
    );
  }
}

class _PromptPreviewModeSwitcher extends StatelessWidget {
  const _PromptPreviewModeSwitcher({
    required this.mode,
    required this.onChanged,
  });

  final _PromptPreviewMode mode;
  final ValueChanged<_PromptPreviewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PromptPreviewModeButton(
            label: 'Readable View',
            icon: Icons.auto_awesome_mosaic_rounded,
            selected: mode == _PromptPreviewMode.readable,
            onPressed: () => onChanged(_PromptPreviewMode.readable),
          ),
          _PromptPreviewModeButton(
            label: 'Raw JSON',
            icon: Icons.data_object_rounded,
            selected: mode == _PromptPreviewMode.rawJson,
            onPressed: () => onChanged(_PromptPreviewMode.rawJson),
          ),
        ],
      ),
    );
  }
}

class _PromptPreviewModeButton extends StatelessWidget {
  const _PromptPreviewModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(
        color: selected ? palette.primaryBright : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? Colors.black : palette.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                      color: selected ? Colors.black : palette.textSecondary,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PromptPreviewReadableView extends StatelessWidget {
  const _PromptPreviewReadableView({
    required this.instructions,
    required this.inputBlocks,
    required this.tools,
    required this.previewMap,
  });

  final String? instructions;
  final List<_PromptPreviewInputBlock> inputBlocks;
  final List<_PromptPreviewToolDefinition> tools;
  final Map<String, Object?> previewMap;

  @override
  Widget build(BuildContext context) {
    final reasoning = previewMap['reasoning'];
    final includeItems = _normalizePreviewList(previewMap['include']);
    final serviceTier = _readNonEmptyString(previewMap['service_tier']);
    final promptCacheKey = _readNonEmptyString(previewMap['prompt_cache_key']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PromptPreviewSectionCard(
          title: 'Request Overview',
          subtitle: 'High-level runtime flags from the generated Responses payload.',
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _PromptPreviewFact(
                label: 'Reasoning',
                value: reasoning == null ? 'disabled' : 'configured',
              ),
              _PromptPreviewFact(
                label: 'Include fields',
                value: includeItems.isEmpty ? 'none' : includeItems.length.toString(),
              ),
              _PromptPreviewFact(
                label: 'Service tier',
                value: serviceTier ?? 'default',
              ),
              _PromptPreviewFact(
                label: 'Prompt cache key',
                value: promptCacheKey ?? 'not set',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _PromptPreviewSectionCard(
          title: 'System Instructions',
          subtitle: 'The `instructions` field sent directly to the model.',
          child: _PromptPreviewCodeBlock(
            text: instructions ?? 'No instructions generated.',
            empty: instructions == null,
          ),
        ),
        const SizedBox(height: 16),
        _PromptPreviewSectionCard(
          title: 'Context Blocks',
          subtitle:
              'Static developer and environment blocks assembled into `input[]`. Conversation turns stay excluded here by design.',
          child: inputBlocks.isEmpty
              ? const _PromptPreviewEmptyMessage(
                  text: 'No static context blocks were generated for this preview.',
                )
              : Column(
                  children: [
                    for (var index = 0; index < inputBlocks.length; index += 1) ...[
                      _PromptPreviewInputBlockCard(block: inputBlocks[index]),
                      if (index < inputBlocks.length - 1) const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _PromptPreviewSectionCard(
          title: 'Tools',
          subtitle:
              'Tool registry, descriptions, and parameter requirements extracted from the generated request.',
          child: tools.isEmpty
              ? const _PromptPreviewEmptyMessage(
                  text: 'No tools were attached to this request.',
                )
              : Column(
                  children: [
                    for (var index = 0; index < tools.length; index += 1) ...[
                      _PromptPreviewToolCard(tool: tools[index]),
                      if (index < tools.length - 1) const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _PromptPreviewRawJsonView extends StatelessWidget {
  const _PromptPreviewRawJsonView({
    required this.rawJson,
  });

  final String rawJson;

  @override
  Widget build(BuildContext context) {
    return _PromptPreviewSectionCard(
      title: 'Raw JSON',
      subtitle: 'Exact preview payload for line-by-line verification against runtime traffic.',
      child: _PromptPreviewCodeBlock(text: rawJson),
    );
  }
}

class _PromptPreviewSectionCard extends StatelessWidget {
  const _PromptPreviewSectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return AiSettingsCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFamily: 'Space Grotesk',
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                  height: 1.5,
                ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _PromptPreviewFact extends StatelessWidget {
  const _PromptPreviewFact({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      constraints: const BoxConstraints(minWidth: 180),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: palette.textMuted,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: palette.textPrimary,
                  fontFamily: 'JetBrains Mono',
                ),
          ),
        ],
      ),
    );
  }
}

class _PromptPreviewCodeBlock extends StatelessWidget {
  const _PromptPreviewCodeBlock({
    required this.text,
    this.empty = false,
  });

  final String text;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.glassStroke),
      ),
      child: SelectableText(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontFamily: 'JetBrains Mono',
              height: 1.55,
              color: empty ? palette.textMuted : palette.textSecondary,
            ),
      ),
    );
  }
}

class _PromptPreviewInputBlockCard extends StatelessWidget {
  const _PromptPreviewInputBlockCard({
    required this.block,
  });

  final _PromptPreviewInputBlock block;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AiSettingsChip(label: 'role: ${block.role}'),
              AiSettingsChip(label: 'type: ${block.type}'),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            block.text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontFamily: 'JetBrains Mono',
                  height: 1.55,
                  color: palette.textSecondary,
                ),
          ),
        ],
      ),
    );
  }
}

class _PromptPreviewToolCard extends StatelessWidget {
  const _PromptPreviewToolCard({
    required this.tool,
  });

  final _PromptPreviewToolDefinition tool;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final description = tool.description;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                tool.name,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontFamily: 'Space Grotesk',
                      fontWeight: FontWeight.w700,
                      color: palette.textPrimary,
                    ),
              ),
              AiSettingsChip(label: 'type: ${tool.type}'),
              AiSettingsChip(label: 'params: ${tool.parameters.length}'),
              if (tool.requiredParameters.isNotEmpty)
                AiSettingsChip(label: 'required: ${tool.requiredParameters.length}'),
              if (tool.strict != null)
                AiSettingsChip(label: 'strict: ${tool.strict! ? 'true' : 'false'}'),
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 12),
            SelectableText(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: palette.textSecondary,
                    height: 1.5,
                  ),
            ),
          ],
          if (tool.requiredParameters.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tool.requiredParameters
                  .map((param) => AiSettingsChip(label: 'required `$param`'))
                  .toList(growable: false),
            ),
          ],
          if (tool.parameters.isNotEmpty) ...[
            const SizedBox(height: 12),
            // Tool schemas vary a lot across built-in tools and MCP tools. Keep
            // the summary card readable, and let parameter-level detail expand
            // only when someone wants to inspect usage constraints closely.
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 8),
              title: Text(
                'Parameter Details',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: palette.textPrimary,
                    ),
              ),
              children: [
                Column(
                  children: [
                    for (var index = 0; index < tool.parameters.length; index += 1) ...[
                      _PromptPreviewToolParameterCard(parameter: tool.parameters[index]),
                      if (index < tool.parameters.length - 1) const SizedBox(height: 10),
                    ],
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PromptPreviewToolParameterCard extends StatelessWidget {
  const _PromptPreviewToolParameterCard({
    required this.parameter,
  });

  final _PromptPreviewToolParameter parameter;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Text(
                parameter.name,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: palette.textPrimary,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                    ),
              ),
              if (parameter.type != null) AiSettingsChip(label: parameter.type!),
              if (parameter.required) const AiSettingsChip(label: 'required'),
            ],
          ),
          if (parameter.description != null) ...[
            const SizedBox(height: 10),
            SelectableText(
              parameter.description!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                    height: 1.5,
                  ),
            ),
          ],
          if (parameter.enumValues.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: parameter.enumValues
                  .map((value) => AiSettingsChip(label: value))
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }
}

class _PromptPreviewEmptyMessage extends StatelessWidget {
  const _PromptPreviewEmptyMessage({
    required this.text,
  });

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: palette.textMuted,
          ),
    );
  }
}

class _PromptPreviewInputBlock {
  const _PromptPreviewInputBlock({
    required this.role,
    required this.type,
    required this.text,
  });

  final String role;
  final String type;
  final String text;
}

class _PromptPreviewToolDefinition {
  const _PromptPreviewToolDefinition({
    required this.name,
    required this.type,
    required this.parameters,
    required this.requiredParameters,
    this.description,
    this.strict,
  });

  final String name;
  final String type;
  final String? description;
  final bool? strict;
  final List<_PromptPreviewToolParameter> parameters;
  final List<String> requiredParameters;
}

class _PromptPreviewToolParameter {
  const _PromptPreviewToolParameter({
    required this.name,
    required this.required,
    this.type,
    this.description,
    this.enumValues = const [],
  });

  final String name;
  final bool required;
  final String? type;
  final String? description;
  final List<String> enumValues;
}

Map<String, Object?> _normalizePreviewMap(Object? value) {
  // The preview payload is sourced from runtime JSON. Normalize every map to
  // string-keyed access so the UI stays stable even if tool schema objects come
  // from slightly different serializers.
  if (value is! Map) {
    return const {};
  }
  return {
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}

List<Object?> _normalizePreviewList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return List<Object?>.from(value);
}

String? _readNonEmptyString(Object? value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _prettyPreviewJson(Object? value) {
  try {
    return JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

List<String> _readStringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value.map((item) => item.toString()).toList(growable: false);
}

String? _extractContentText(Map<String, Object?> contentMap) {
  for (final key in const ['input_text', 'text', 'output_text']) {
    final value = _readNonEmptyString(contentMap[key]);
    if (value != null) {
      return value;
    }
  }
  return null;
}

List<_PromptPreviewInputBlock> _extractPreviewInputBlocks(Map<String, Object?> previewMap) {
  final blocks = <_PromptPreviewInputBlock>[];
  for (final inputItem in _normalizePreviewList(previewMap['input'])) {
    final itemMap = _normalizePreviewMap(inputItem);
    final role = _readNonEmptyString(itemMap['role']) ?? 'unknown';
    final content = itemMap['content'];

    if (content is String && content.trim().isNotEmpty) {
      blocks.add(
        _PromptPreviewInputBlock(
          role: role,
          type: 'text',
          text: content,
        ),
      );
      continue;
    }

    for (final contentItem in _normalizePreviewList(content)) {
      final contentMap = _normalizePreviewMap(contentItem);
      final text = _extractContentText(contentMap);
      if (text == null) {
        continue;
      }
      blocks.add(
        _PromptPreviewInputBlock(
          role: role,
          type: _readNonEmptyString(contentMap['type']) ?? 'content',
          text: text,
        ),
      );
    }
  }
  return blocks;
}

List<_PromptPreviewToolDefinition> _extractPreviewTools(Map<String, Object?> previewMap) {
  final tools = <_PromptPreviewToolDefinition>[];

  for (final toolValue in _normalizePreviewList(previewMap['tools'])) {
    final toolMap = _normalizePreviewMap(toolValue);
    final parametersMap = _normalizePreviewMap(toolMap['parameters']);
    final propertiesMap = _normalizePreviewMap(parametersMap['properties']);
    final requiredParameters = _readStringList(parametersMap['required']);
    final requiredLookup = requiredParameters.toSet();
    final parameters = <_PromptPreviewToolParameter>[];

    for (final entry in propertiesMap.entries) {
      final propertyMap = _normalizePreviewMap(entry.value);
      final typeValue = propertyMap['type'];
      final parameterType = switch (typeValue) {
        String() => typeValue,
        List() => typeValue.map((item) => item.toString()).join(' | '),
        _ => null,
      };
      parameters.add(
        _PromptPreviewToolParameter(
          name: entry.key,
          required: requiredLookup.contains(entry.key),
          type: parameterType,
          description: _readNonEmptyString(propertyMap['description']),
          enumValues: _readStringList(propertyMap['enum']),
        ),
      );
    }

    tools.add(
      _PromptPreviewToolDefinition(
        name: _readNonEmptyString(toolMap['name']) ??
            _readNonEmptyString(toolMap['type']) ??
            'unnamed_tool',
        type: _readNonEmptyString(toolMap['type']) ?? 'unknown',
        description: _readNonEmptyString(toolMap['description']),
        strict: toolMap['strict'] is bool ? toolMap['strict'] as bool : null,
        parameters: parameters,
        requiredParameters: requiredParameters,
      ),
    );
  }

  return tools;
}
