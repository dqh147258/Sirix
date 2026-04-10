import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../settings_ui.dart';
import '../ai_settings_view_model.dart';

class McpSettingsSection extends StatelessWidget {
  const McpSettingsSection({
    super.key,
    required this.state,
    required this.vm,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final mcpGlobal = state.config.mcp;

    return ListView(
      children: [
        AiSettingsSectionHeader(
          title: 'MCP',
          subtitle: 'Control which external tool servers are available, which transports are allowed, and how each server is filtered.',
          action: FilledButton.icon(
            onPressed: () async {
              final created = await _showMcpDialog(context, vm: vm, existing: null);
              if (created != null) {
                vm.upsertMcpServer(created);
              }
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add MCP Server'),
          ),
        ),
        AiSettingsCard(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              AiSettingsToggleTile(
                title: 'MCP Enabled',
                value: mcpGlobal.enabled,
                onChanged: (value) => vm.updateMcpGlobal(mcpGlobal.copyWith(enabled: value)),
              ),
              AiSettingsToggleTile(
                title: 'Allow Stdio Transport',
                width: 300,
                value: mcpGlobal.allowStdio,
                onChanged: (value) =>
                    vm.updateMcpGlobal(mcpGlobal.copyWith(allowStdio: value)),
              ),
              AiSettingsToggleTile(
                title: 'Allow HTTP Transport',
                width: 300,
                value: mcpGlobal.allowHttp,
                onChanged: (value) => vm.updateMcpGlobal(mcpGlobal.copyWith(allowHttp: value)),
              ),
            ],
          ),
        ),
        if (state.config.mcpServers.isEmpty)
          const AiSettingsEmptyState(text: 'No MCP servers configured.'),
        for (final server in state.config.mcpServers) ...[
          AiSettingsCard(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(server.name, style: Theme.of(context).textTheme.titleMedium),
                    ),
                    IconButton(
                      onPressed: () async {
                        final edited = await _showMcpDialog(context, vm: vm, existing: server);
                        if (edited != null) {
                          vm.upsertMcpServer(edited);
                        }
                      },
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      onPressed: () => vm.removeMcpServer(server.id),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AiSettingsChip(label: server.id),
                    AiSettingsChip(label: 'approval=${_enumName(server.approvalMode)}'),
                    AiSettingsChip(label: server.enabled ? 'enabled' : 'disabled'),
                  ],
                ),
                if (server.enabledTools.isNotEmpty || server.disabledTools.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (server.enabledTools.isNotEmpty)
                          AiSettingsChip(label: 'enabled: ${server.enabledTools.join(', ')}'),
                        if (server.disabledTools.isNotEmpty)
                          AiSettingsChip(label: 'disabled: ${server.disabledTools.join(', ')}'),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                AiSettingsToggleTile(
                  title: 'Enabled',
                  value: server.enabled,
                  onChanged: (value) => vm.upsertMcpServer(server.copyWith(enabled: value)),
                ),
                const SizedBox(height: 10),
                Text(
                  server.jsonConfig,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'JetBrains Mono',
                      ),
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

Future<McpServerConfigModel?> _showMcpDialog(
  BuildContext context, {
  required AiSettingsViewModel vm,
  required McpServerConfigModel? existing,
}) async {
  final idController = TextEditingController(text: existing?.id ?? vm.createStableId('mcp'));
  final nameController = TextEditingController(text: existing?.name ?? 'New MCP');
  final jsonController = TextEditingController(text: existing?.jsonConfig ?? '{}');
  final enabledToolsController =
      TextEditingController(text: existing?.enabledTools.join(',') ?? '');
  final disabledToolsController =
      TextEditingController(text: existing?.disabledTools.join(',') ?? '');
  var enabled = existing?.enabled ?? true;
  var approvalMode = existing?.approvalMode ?? ApprovalMode.allow;

  final submitted = await showAiSettingsDialog<bool>(
    context: context,
    title: existing == null ? 'Add MCP Server' : 'Edit MCP Server',
    subtitle: 'Define the MCP transport payload, filter tool exposure, and assign the default approval mode.',
    width: 700,
    child: StatefulBuilder(
      builder: (context, setState) {
        return AiSettingsFieldGroup(
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(labelText: 'MCP ID'),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'MCP Name'),
            ),
            DropdownButtonFormField<ApprovalMode>(
              value: approvalMode,
              decoration: const InputDecoration(labelText: 'Approval Mode'),
              items: ApprovalMode.values
                  .map((value) => DropdownMenuItem(
                        value: value,
                        child: Text(_enumName(value)),
                      ))
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() => approvalMode = value);
                }
              },
            ),
            AiSettingsToggleTile(
              title: 'Enabled',
              value: enabled,
              onChanged: (value) => setState(() => enabled = value),
            ),
            TextField(
              controller: jsonController,
              minLines: 8,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'JSON Config',
                border: OutlineInputBorder(),
              ),
            ),
            TextField(
              controller: enabledToolsController,
              decoration: const InputDecoration(
                labelText: 'Enabled Tools (comma separated)',
              ),
            ),
            TextField(
              controller: disabledToolsController,
              decoration: const InputDecoration(
                labelText: 'Disabled Tools (comma separated)',
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

  return McpServerConfigModel(
    id: idController.text.trim(),
    name: nameController.text.trim(),
    enabled: enabled,
    approvalMode: approvalMode,
    enabledTools: _parseCsv(enabledToolsController.text),
    disabledTools: _parseCsv(disabledToolsController.text),
    jsonConfig: jsonController.text.trim().isEmpty ? '{}' : jsonController.text.trim(),
  );
}

List<String> _parseCsv(String raw) {
  return raw
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

String _enumName(Object value) => value.toString().split('.').last;
