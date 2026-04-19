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
  _PermissionsTab _selectedTab = _PermissionsTab.builtin;

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
    final discoveredMcpServers = {
      for (final server in widget.state.statusOverview?.mcp.servers ?? const <LocalMcpServerStatus>[])
        server.id: server,
    };
    final mcpItems = <_CapabilityApprovalItem>[
      for (final server in widget.state.config.mcpServers) ...[
        _CapabilityApprovalItem(id: 'mcp.${server.id}', label: server.name, description: server.id),
        for (final tool in discoveredMcpServers[server.id]?.discoveredTools ?? const <LocalMcpServerToolStatus>[])
          _CapabilityApprovalItem(
            id: 'mcp.${server.id}.${tool.id}',
            label: '${server.name} · ${tool.title}',
            description: tool.description ?? tool.id,
          ),
      ],
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        AiSettingsSectionHeader(
          title: 'Permissions',
          subtitle:
              'Configure approval defaults only. MCP transport/server management stays on the MCP page, while agent resource selection stays on the Agents page.',
        ),
        const SizedBox(height: 16),
        _PermissionsTabBar(
          selectedTab: _selectedTab,
          onChanged: (tab) => setState(() => _selectedTab = tab),
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: KeyedSubtree(
            key: ValueKey(_selectedTab),
            child: switch (_selectedTab) {
              _PermissionsTab.builtin => _CapabilityApprovalCard(
                title: 'Builtin Tool Permissions',
                subtitle:
                    'Set the global default mode for builtin tools and optionally override individual builtin tools.',
                config: widget.state.config.builtinApprovals,
                items: [
                  for (final id in kBuiltinToolCatalog)
                    _CapabilityApprovalItem(id: 'builtin.$id', label: id),
                ],
                onChanged: widget.vm.updateBuiltinApprovals,
              ),
              _PermissionsTab.skills => _CapabilityApprovalCard(
                title: 'Skill Permissions',
                subtitle:
                    'Set the global default mode for skills and optionally override individual configured skills.',
                config: widget.state.config.skillApprovals,
                items: [
                  for (final skill in widget.state.config.skills)
                    _CapabilityApprovalItem(
                      id: 'skill.${skill.id}',
                      label: skill.name,
                      description: skill.path,
                    ),
                ],
                onChanged: widget.vm.updateSkillApprovals,
              ),
              _PermissionsTab.mcp => _CapabilityApprovalCard(
                title: 'MCP Permissions',
                subtitle:
                    'Set the global default mode for MCP calls and optionally override individual servers/functions discovered from the Desktop Server MCP probe.',
                config: widget.state.config.mcpApprovals,
                items: mcpItems,
                onChanged: widget.vm.updateMcpApprovals,
              ),
              _PermissionsTab.shell => Column(
                children: [
                  AiSettingsCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Shell Authorization',
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
                        ApprovalModeSegmentedControl(
                          value: shellRules.mode,
                          onChanged: (mode) {
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
                        subtitle:
                            'Used when mode is `allow` or after you persist an allow decision from the runtime.',
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
                        subtitle:
                            'Applied in both `allow` and `ask` modes. Default protections such as `rm -rf` should stay here unless you have a strong reason.',
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
              ),
              _PermissionsTab.agents => _AgentApprovalsCard(
                state: widget.state,
                vm: widget.vm,
              ),
            },
          ),
        ),
      ],
    );
  }
}

enum _PermissionsTab {
  builtin,
  skills,
  mcp,
  shell,
  agents,
}

extension on _PermissionsTab {
  String get label => switch (this) {
        _PermissionsTab.builtin => 'Builtin',
        _PermissionsTab.skills => 'Skills',
        _PermissionsTab.mcp => 'MCP',
        _PermissionsTab.shell => 'Shell',
        _PermissionsTab.agents => 'Agents',
      };

  IconData get icon => switch (this) {
        _PermissionsTab.builtin => Icons.build_circle_outlined,
        _PermissionsTab.skills => Icons.auto_awesome_rounded,
        _PermissionsTab.mcp => Icons.extension_rounded,
        _PermissionsTab.shell => Icons.terminal_rounded,
        _PermissionsTab.agents => Icons.smart_toy_rounded,
      };
}

class _PermissionsTabBar extends StatelessWidget {
  const _PermissionsTabBar({
    required this.selectedTab,
    required this.onChanged,
  });

  final _PermissionsTab selectedTab;
  final ValueChanged<_PermissionsTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return AiSettingsCard(
      padding: const EdgeInsets.all(8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tab in _PermissionsTab.values) ...[
              _PermissionsTabButton(
                tab: tab,
                selected: tab == selectedTab,
                onTap: () => onChanged(tab),
              ),
              if (tab != _PermissionsTab.values.last) const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _PermissionsTabButton extends StatelessWidget {
  const _PermissionsTabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _PermissionsTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? palette.primaryBright.withValues(alpha: 0.14)
                : palette.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? palette.primaryBright.withValues(alpha: 0.36)
                  : palette.glassStroke,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                tab.icon,
                size: 17,
                color: selected ? palette.primaryBright : palette.textMuted,
              ),
              const SizedBox(width: 8),
              Text(
                tab.label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: selected ? palette.textPrimary : palette.textSecondary,
                    ),
              ),
            ],
          ),
        ),
      ),
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

class _CapabilityApprovalItem {
  const _CapabilityApprovalItem({
    required this.id,
    required this.label,
    this.description,
  });

  final String id;
  final String label;
  final String? description;
}

class _CapabilityApprovalCard extends StatelessWidget {
  const _CapabilityApprovalCard({
    required this.title,
    required this.subtitle,
    required this.config,
    required this.items,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final CapabilityRulesConfigModel config;
  final List<_CapabilityApprovalItem> items;
  final ValueChanged<CapabilityRulesConfigModel> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return AiSettingsCard(
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
            onChanged: (value) {
              onChanged(config.copyWith(mode: value));
            },
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final item in items) ...[
              _CapabilityApprovalRow(
                item: item,
                mode: _modeForCapabilityRule(config, item.id),
                onChanged: (nextMode) {
                  if (nextMode == null) {
                    return;
                  }
                  onChanged(_updateCapabilityRule(config, item.id, nextMode));
                },
              ),
              if (item != items.last) const Divider(height: 20),
            ],
          ],
        ],
      ),
    );
  }
}

class _CapabilityApprovalRow extends StatelessWidget {
  const _CapabilityApprovalRow({
    required this.item,
    required this.mode,
    required this.onChanged,
  });

  final _CapabilityApprovalItem item;
  final ApprovalMode mode;
  final ValueChanged<ApprovalMode?> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return LayoutBuilder(
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
            if (item.description != null && item.description!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                item.description!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                    ),
              ),
            ],
          ],
        );
        final control = SizedBox(
          width: stacked ? double.infinity : 240,
          child: ApprovalModeSegmentedControl(
            value: mode,
            dense: true,
            onChanged: (value) => onChanged(value),
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
    );
  }
}

class _AgentApprovalsCard extends StatelessWidget {
  const _AgentApprovalsCard({
    required this.state,
    required this.vm,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return AiSettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AiSettingsSectionHeader(
            title: 'Agent Approval Overrides',
            subtitle:
                'Tune shell authorization per agent from the same approval surface. Use the Agents page for provider/model selection, enabled resources, and prompt editing.',
            action: OutlinedButton.icon(
              onPressed: () => vm.selectSection(AiSettingsSection.agents),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Open Agents'),
            ),
          ),
          if (state.config.agents.isEmpty)
            const AiSettingsEmptyState(text: 'No agent profiles configured yet.')
          else
            for (final agent in state.config.agents) ...[
              _AgentApprovalRow(
                agent: agent,
                onChanged: (mode) {
                  vm.upsertAgent(agent.copyWith(approvalMode: mode));
                },
              ),
              if (agent != state.config.agents.last)
                Divider(
                  height: 24,
                  color: palette.glassStroke,
                ),
            ],
        ],
      ),
    );
  }
}

class _AgentApprovalRow extends StatelessWidget {
  const _AgentApprovalRow({
    required this.agent,
    required this.onChanged,
  });

  final AgentConfigModel agent;
  final ValueChanged<ApprovalMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 860;
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              agent.name,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              agent.description.trim().isEmpty ? agent.id : agent.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                  ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AiSettingsChip(label: 'Builtin ${approvalModeLabel(agent.builtinApprovals.mode)}'),
                AiSettingsChip(label: 'Skills ${approvalModeLabel(agent.skillApprovals.mode)}'),
                AiSettingsChip(label: 'MCP ${approvalModeLabel(agent.mcpApprovals.mode)}'),
                AiSettingsChip(label: _agentShellRulesSummary(agent.shellRules)),
              ],
            ),
          ],
        );
        final control = SizedBox(
          width: stacked ? double.infinity : 240,
          child: ApprovalModeSegmentedControl(
            value: agent.approvalMode,
            dense: true,
            onChanged: onChanged,
          ),
        );

        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              details,
              const SizedBox(height: 14),
              control,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: details),
            const SizedBox(width: 16),
            control,
          ],
        );
      },
    );
  }
}

ApprovalMode _modeForCapabilityRule(CapabilityRulesConfigModel config, String key) {
  for (final rule in config.rules) {
    if (rule.key == key) {
      return rule.mode;
    }
  }
  return config.mode;
}

CapabilityRulesConfigModel _updateCapabilityRule(
  CapabilityRulesConfigModel config,
  String key,
  ApprovalMode mode,
) {
  final nextRules = [
    for (final rule in config.rules)
      if (rule.key != key) rule,
    CapabilityApprovalRuleModel(key: key, mode: mode),
  ];
  return config.copyWith(rules: nextRules);
}

List<String> _parseRuleLines(String raw) {
  return raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
}

String _agentShellRulesSummary(ShellRulesConfigModel shellRules) {
  if (shellRules.allow.isEmpty && shellRules.deny.isEmpty) {
    return 'No shell lists';
  }
  return 'Allow ${shellRules.allow.length} · Deny ${shellRules.deny.length}';
}
