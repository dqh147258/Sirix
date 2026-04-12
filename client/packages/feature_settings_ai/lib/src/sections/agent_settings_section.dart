import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../settings_ui.dart';
import '../ai_settings_view_model.dart';

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
        !widget.state.config.agents.any((a) => a.id == _selectedAgentId)) {
      _selectedAgentId = null;
    }
    if (_selectedAgentId == null && widget.state.config.agents.isNotEmpty) {
      _selectedAgentId = widget.state.config.agents.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The page shell already collapses at 1100px, so the agent workspace
        // needs three internal modes: full sidebar, icon-only sidebar, then stacked.
        final useStackedLayout = constraints.maxWidth < 680;
        final useCollapsedSidebar = !useStackedLayout && constraints.maxWidth < 980;
        final listPane = _AgentListPane(
          mode: useStackedLayout
              ? _AgentListPaneMode.stacked
              : useCollapsedSidebar
                  ? _AgentListPaneMode.collapsed
                  : _AgentListPaneMode.full,
          state: widget.state,
          selectedAgentId: _selectedAgentId,
          onSelect: (agentId) => setState(() => _selectedAgentId = agentId),
          onCreate: () async {
            final created = await _showAgentDialog(
              context,
              state: widget.state,
              vm: widget.vm,
              existing: null,
            );
            if (created != null) {
              widget.vm.upsertAgent(created);
              setState(() => _selectedAgentId = created.id);
            }
          },
        );

        final detailPane = Container(
          color: palette.background.withValues(alpha: 0.5),
          child: _selectedAgentId == null
              ? Center(
                  child: Text(
                    'Select or create an agent.',
                    style: TextStyle(color: palette.textMuted),
                  ),
                )
              : _AgentDetailForm(
                  agent: widget.state.config.agents.firstWhere((a) => a.id == _selectedAgentId),
                  state: widget.state,
                  vm: widget.vm,
                  onEditForm: () async {
                    final agent = widget.state.config.agents.firstWhere(
                      (a) => a.id == _selectedAgentId,
                    );
                    final edited = await _showAgentDialog(
                      context,
                      state: widget.state,
                      vm: widget.vm,
                      existing: agent,
                    );
                    if (edited != null) {
                      widget.vm.upsertAgent(edited);
                    }
                  },
                ),
        );

        if (useStackedLayout) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 240, child: listPane),
              const SizedBox(height: 12),
              Expanded(child: detailPane),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: useCollapsedSidebar ? 88 : 280, child: listPane),
            Expanded(child: detailPane),
          ],
        );
      },
    );
  }
}

class _AgentListPane extends StatelessWidget {
  const _AgentListPane({
    required this.mode,
    required this.state,
    required this.selectedAgentId,
    required this.onSelect,
    required this.onCreate,
  });

  final _AgentListPaneMode mode;
  final AiSettingsState state;
  final String? selectedAgentId;
  final ValueChanged<String> onSelect;
  final Future<void> Function() onCreate;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final isCollapsed = mode == _AgentListPaneMode.collapsed;
    final isStacked = mode == _AgentListPaneMode.stacked;
    return Container(
      decoration: BoxDecoration(
        border: isStacked
            ? Border(bottom: BorderSide(color: palette.glassStroke))
            : Border(right: BorderSide(color: palette.glassStroke)),
        color: palette.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.all(isCollapsed ? 16 : 20),
            child: isCollapsed
                ? Tooltip(
                    message: 'Agents',
                    child: Icon(
                      Icons.smart_toy_rounded,
                      color: palette.primaryBright,
                    ),
                  )
                : Text(
                    'ACTIVE AGENTS',
                    style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2.0,
                      color: palette.primaryBright,
                    ),
                  ),
          ),
          Expanded(
            child: state.config.agents.isEmpty
                ? Center(
                    child: isCollapsed
                        ? Tooltip(
                            message: 'No agents configured.',
                            child: Icon(
                              Icons.info_outline_rounded,
                              color: palette.textMuted,
                            ),
                          )
                        : Text(
                            'No agents configured.',
                            style: TextStyle(color: palette.textMuted),
                          ),
                  )
                : ListView.builder(
                    itemCount: state.config.agents.length,
                    itemBuilder: (context, index) {
                      final agent = state.config.agents[index];
                      final isSelected = agent.id == selectedAgentId;
                      return Tooltip(
                        message: agent.name,
                        waitDuration: const Duration(milliseconds: 250),
                        child: InkWell(
                          onTap: () => onSelect(agent.id),
                          child: Container(
                            padding: EdgeInsets.all(isCollapsed ? 12 : 16),
                            decoration: BoxDecoration(
                              color: isSelected ? palette.surfaceRaised : Colors.transparent,
                              border: Border(
                                bottom: BorderSide(color: palette.surfaceMuted),
                                left: BorderSide(
                                  color: isSelected ? palette.primaryBright : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: isCollapsed
                                ? Center(
                                    child: Icon(
                                      Icons.smart_toy_rounded,
                                      size: 22,
                                      color: isSelected
                                          ? palette.primaryBright
                                          : agent.enabled
                                              ? palette.textSecondary
                                              : palette.textMuted,
                                    ),
                                  )
                                : Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              agent.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: 'JetBrains Mono',
                                                fontWeight: FontWeight.w700,
                                                color: isSelected ? Colors.white : palette.textSecondary,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'ID: ${agent.id}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: 'JetBrains Mono',
                                                fontSize: 10,
                                                color: palette.textMuted,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                Container(
                                                  width: 6,
                                                  height: 6,
                                                  decoration: BoxDecoration(
                                                    color: agent.enabled
                                                        ? palette.primaryBright
                                                        : palette.textMuted,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  agent.enabled ? 'ACTIVE' : 'OFFLINE',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w800,
                                                    color: agent.enabled
                                                        ? palette.primaryBright
                                                        : palette.textMuted,
                                                    letterSpacing: 0.5,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: EdgeInsets.all(isCollapsed ? 12 : 16),
            child: isCollapsed
                ? Tooltip(
                    message: 'New Agent',
                    child: FilledButton(
                      onPressed: onCreate,
                      style: FilledButton.styleFrom(
                        backgroundColor: palette.surfaceMuted,
                        foregroundColor: palette.primaryBright,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Icon(Icons.add_rounded),
                    ),
                  )
                : FilledButton.icon(
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('NEW AGENT'),
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.surfaceMuted,
                      foregroundColor: palette.primaryBright,
                      textStyle: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

enum _AgentListPaneMode {
  full,
  collapsed,
  stacked,
}

class _AgentDetailForm extends StatelessWidget {
  const _AgentDetailForm({
    required this.agent,
    required this.state,
    required this.vm,
    required this.onEditForm,
  });

  final AgentConfigModel agent;
  final AiSettingsState state;
  final AiSettingsViewModel vm;
  final VoidCallback onEditForm;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Preserve the split-panel aesthetic, but stack high-density rows when
        // the details pane narrows so the page still works at the minimum desktop size.
        final useCompactDetails = constraints.maxWidth < 860;
        return ListView(
          padding: const EdgeInsets.all(40),
          children: [
            if (useCompactDetails)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AgentHeading(agent: agent),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Switch(
                        value: agent.enabled,
                        onChanged: (val) => vm.upsertAgent(agent.copyWith(enabled: val)),
                        activeThumbColor: palette.primaryBright,
                      ),
                      OutlinedButton.icon(
                        onPressed: onEditForm,
                        icon: const Icon(Icons.edit_rounded, size: 16),
                        label: const Text('Edit Full Config'),
                      ),
                      IconButton(
                        onPressed: () => vm.removeAgent(agent.id),
                        icon: const Icon(Icons.delete_outline_rounded),
                        color: palette.error,
                        tooltip: 'Delete Agent',
                      ),
                    ],
                  ),
                ],
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _AgentHeading(agent: agent),
                  Row(
                    children: [
                      Switch(
                        value: agent.enabled,
                        onChanged: (val) => vm.upsertAgent(agent.copyWith(enabled: val)),
                        activeThumbColor: palette.primaryBright,
                      ),
                      const SizedBox(width: 16),
                      OutlinedButton.icon(
                        onPressed: onEditForm,
                        icon: const Icon(Icons.edit_rounded, size: 16),
                        label: const Text('Edit Full Config'),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => vm.removeAgent(agent.id),
                        icon: const Icon(Icons.delete_outline_rounded),
                        color: palette.error,
                        tooltip: 'Delete Agent',
                      ),
                    ],
                  ),
                ],
              ),
            const SizedBox(height: 40),

            _SectionHeader(title: '01. Agent Identity & Model', color: palette.secondary),
            const SizedBox(height: 16),
            if (useCompactDetails) ...[
              _DetailBox(label: 'PROVIDER', value: agent.providerId),
              const SizedBox(height: 16),
              _DetailBox(label: 'MODEL', value: agent.modelId),
            ] else
              Row(
                children: [
                  Expanded(
                    child: _DetailBox(label: 'PROVIDER', value: agent.providerId),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _DetailBox(label: 'MODEL', value: agent.modelId),
                  ),
                ],
              ),

            const SizedBox(height: 32),
            _SectionHeader(title: '02. Capabilities', color: palette.secondary),
            const SizedBox(height: 16),
            if (useCompactDetails) ...[
              _CapabilityPanel(
                title: 'MCP Servers',
                icon: Icons.extension_rounded,
                enabledIds: agent.enabledMcpServerIds,
                allCount: agent.enabledMcpServerIds.length + agent.disabledMcpServerIds.length,
              ),
              const SizedBox(height: 16),
              _CapabilityPanel(
                title: 'Local Skills',
                icon: Icons.terminal_rounded,
                enabledIds: agent.enabledSkillIds,
                allCount: agent.enabledSkillIds.length + agent.disabledSkillIds.length,
              ),
              const SizedBox(height: 16),
              _CapabilityPanel(
                title: 'Builtin Tools',
                icon: Icons.build_circle_rounded,
                isToggleOnly: true,
                isToggledOn: agent.builtinToolsEnabled,
                onToggle: (val) => vm.upsertAgent(agent.copyWith(builtinToolsEnabled: val)),
              ),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _CapabilityPanel(
                      title: 'MCP Servers',
                      icon: Icons.extension_rounded,
                      enabledIds: agent.enabledMcpServerIds,
                      allCount: agent.enabledMcpServerIds.length + agent.disabledMcpServerIds.length,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _CapabilityPanel(
                      title: 'Local Skills',
                      icon: Icons.terminal_rounded,
                      enabledIds: agent.enabledSkillIds,
                      allCount: agent.enabledSkillIds.length + agent.disabledSkillIds.length,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _CapabilityPanel(
                      title: 'Builtin Tools',
                      icon: Icons.build_circle_rounded,
                      isToggleOnly: true,
                      isToggledOn: agent.builtinToolsEnabled,
                      onToggle: (val) => vm.upsertAgent(agent.copyWith(builtinToolsEnabled: val)),
                    ),
                  ),
                ],
              ),

            const SizedBox(height: 32),
            _SectionHeader(title: '03. System Prompt', color: palette.secondary),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: palette.surfaceRaised,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.glassStroke),
              ),
              child: Text(
                agent.systemPrompt.isEmpty ? 'No custom system prompt configured.' : agent.systemPrompt,
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 12,
                  color: agent.systemPrompt.isEmpty ? palette.textMuted : palette.textPrimary,
                  height: 1.6,
                ),
              ),
            ),

            const SizedBox(height: 32),
            _SectionHeader(title: '04. Capability Rules', color: palette.secondary),
            const SizedBox(height: 16),
            if (agent.capabilityRules.isEmpty)
              const Text('No capability rules configured.')
            else
              Container(
                decoration: BoxDecoration(
                  color: palette.surfaceRaised,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.glassStroke),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: agent.capabilityRules.length,
                  separatorBuilder: (context, index) => Divider(height: 1, color: palette.glassStroke),
                  itemBuilder: (context, index) {
                    final rule = agent.capabilityRules[index];
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              rule.key,
                              style: TextStyle(fontFamily: 'JetBrains Mono', color: palette.textPrimary),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: rule.approvalMode == ApprovalMode.allow
                                  ? palette.primaryBright.withValues(alpha: 0.1)
                                  : rule.approvalMode == ApprovalMode.deny
                                      ? palette.error.withValues(alpha: 0.1)
                                      : palette.secondary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              rule.approvalMode.name.toUpperCase(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: rule.approvalMode == ApprovalMode.allow
                                    ? palette.primaryBright
                                    : rule.approvalMode == ApprovalMode.deny
                                        ? palette.error
                                        : palette.secondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AgentHeading extends StatelessWidget {
  const _AgentHeading({required this.agent});

  final AgentConfigModel agent;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          agent.name,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontFamily: 'Space Grotesk',
                fontWeight: FontWeight.w700,
                color: palette.primaryBright,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'Configuration for ${agent.id}',
          style: TextStyle(
            color: palette.textMuted,
            fontFamily: 'JetBrains Mono',
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.color});
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w900,
        letterSpacing: 3.0,
        color: color,
        fontFamily: 'Space Grotesk',
      ),
    );
  }
}

class _DetailBox extends StatelessWidget {
  const _DetailBox({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            color: context.sirix.textMuted,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: context.sirix.surfaceMuted,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            value.isEmpty ? 'Not Set' : value,
            style: const TextStyle(fontFamily: 'JetBrains Mono'),
          ),
        ),
      ],
    );
  }
}

class _CapabilityPanel extends StatelessWidget {
  const _CapabilityPanel({
    required this.title,
    required this.icon,
    this.enabledIds = const [],
    this.allCount = 0,
    this.isToggleOnly = false,
    this.isToggledOn = false,
    this.onToggle,
  });

  final String title;
  final IconData icon;
  final List<String> enabledIds;
  final int allCount;
  final bool isToggleOnly;
  final bool isToggledOn;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: palette.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: palette.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (isToggleOnly) ...[
             Switch(
               value: isToggledOn,
               onChanged: onToggle,
               activeThumbColor: palette.primaryBright,
             ),
          ] else ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (enabledIds.isEmpty && allCount == 0)
                  Text('None', style: TextStyle(color: palette.textMuted, fontSize: 12)),
                for (final id in enabledIds)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: palette.primaryBright.withValues(alpha: 0.1),
                      border: Border.all(color: palette.primaryBright.withValues(alpha: 0.3)),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      id,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: palette.primaryBright,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
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
