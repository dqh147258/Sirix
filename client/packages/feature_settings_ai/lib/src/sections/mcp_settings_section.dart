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
        // Global MCP Toggle Area
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
                'MODEL CONTEXT PROTOCOL',
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
                'Configure and manage secure communication layers for local and remote model context delivery. MCP enables agents to safely interact with your local environment.',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  _GlobalToggle(
                    label: 'ENABLE MCP',
                    value: mcpGlobal.enabled,
                    onChanged: (val) => vm.updateMcpGlobal(mcpGlobal.copyWith(enabled: val)),
                  ),
                  _GlobalToggle(
                    label: 'ALLOW STDIO',
                    value: mcpGlobal.allowStdio,
                    onChanged: (val) => vm.updateMcpGlobal(mcpGlobal.copyWith(allowStdio: val)),
                  ),
                  _GlobalToggle(
                    label: 'ALLOW HTTP',
                    value: mcpGlobal.allowHttp,
                    onChanged: (val) => vm.updateMcpGlobal(mcpGlobal.copyWith(allowHttp: val)),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Header & Add Action
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.dns_rounded, color: palette.secondary, size: 24),
                const SizedBox(width: 12),
                Text(
                  'REGISTERED MCP SERVERS',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.0,
                    color: palette.textSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: palette.surfaceRaised,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${state.config.mcpServers.where((s) => s.enabled).length} ACTIVE',
                    style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 10,
                      color: palette.secondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: () async {
                final created = await _showMcpDialog(context, vm: vm, existing: null);
                if (created != null) {
                  vm.upsertMcpServer(created);
                }
              },
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('ADD SERVER'),
              style: TextButton.styleFrom(
                foregroundColor: palette.primaryBright,
                textStyle: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.0),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Bento Grid of Servers
        LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = constraints.maxWidth < 650 ? constraints.maxWidth : (constraints.maxWidth - 24) / 2;
            return Wrap(
              spacing: 24,
              runSpacing: 24,
              children: [
                for (final server in state.config.mcpServers)
                  SizedBox(
                    width: cardWidth,
                    child: _McpServerCard(
                      server: server,
                      vm: vm,
                      onEdit: () async {
                        final edited = await _showMcpDialog(context, vm: vm, existing: server);
                        if (edited != null) {
                          vm.upsertMcpServer(edited);
                        }
                      },
                    ),
                  ),
                SizedBox(
                  width: cardWidth,
                  child: InkWell(
                    onTap: () async {
                      final created = await _showMcpDialog(context, vm: vm, existing: null);
                      if (created != null) {
                        vm.upsertMcpServer(created);
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      height: 380, // Matches approximate height of cards
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: palette.glassStroke,
                          style: BorderStyle.solid,
                        ),
                        borderRadius: BorderRadius.circular(8),
                        color: palette.surfaceRaised.withValues(alpha: 0.3),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: palette.surfaceRaised,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.add_box_rounded, color: palette.textMuted, size: 32),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'PROVISION NEW SERVER',
                            style: TextStyle(
                              fontFamily: 'Space Grotesk',
                              color: palette.textPrimary,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Bootstrap a new MCP compliant endpoint',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _GlobalToggle extends StatelessWidget {
  const _GlobalToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            height: 20,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeColor: palette.primaryBright,
            ),
          ),
        ],
      ),
    );
  }
}

class _McpServerCard extends StatelessWidget {
  const _McpServerCard({
    required this.server,
    required this.vm,
    required this.onEdit,
  });

  final McpServerConfigModel server;
  final AiSettingsViewModel vm;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final isEnabled = server.enabled;
    
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.glassStroke),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      foregroundDecoration: isEnabled
          ? null
          : BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isEnabled ? palette.primaryBright.withValues(alpha: 0.1) : palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    isEnabled ? Icons.storage_rounded : Icons.cloud_off_rounded,
                    color: isEnabled ? palette.primaryBright : palette.textMuted,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.name,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontFamily: 'Space Grotesk',
                              fontWeight: FontWeight.w700,
                              color: isEnabled ? palette.textPrimary : palette.textMuted,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: ${server.id}',
                        style: TextStyle(
                          fontFamily: 'JetBrains Mono',
                          fontSize: 11,
                          color: palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      isEnabled ? 'ACTIVE' : 'DISABLED',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                        color: isEnabled ? palette.primaryBright : palette.textMuted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 20,
                      child: Switch(
                        value: isEnabled,
                        onChanged: (val) => vm.upsertMcpServer(server.copyWith(enabled: val)),
                        activeColor: palette.primaryBright,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          Divider(height: 1, color: palette.glassStroke),
          
          // Body
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Approval Mode 
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'APPROVAL MODE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                        color: palette.textMuted,
                      ),
                    ),
                    Row(
                      children: ApprovalMode.values.map((mode) {
                        final isSelected = server.approvalMode == mode;
                        return Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: InkWell(
                            onTap: () => vm.upsertMcpServer(server.copyWith(approvalMode: mode)),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isSelected ? palette.primaryBright : palette.surfaceMuted,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _enumName(mode).toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: isSelected ? Colors.black : palette.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
                
                const SizedBox(height: 24),
                
                // Config Editor
                Text(
                  'CONFIG EDITOR',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: palette.textMuted,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  height: 140,
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(4),
                    border: Border(left: BorderSide(color: palette.primaryBright.withValues(alpha: 0.3), width: 2)),
                  ),
                  child: Stack(
                    children: [
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          server.jsonConfig.isEmpty ? '{}' : server.jsonConfig,
                          style: TextStyle(
                            fontFamily: 'JetBrains Mono',
                            fontSize: 11,
                            color: palette.primaryBright.withValues(alpha: 0.8),
                            height: 1.5,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IconButton(
                          onPressed: onEdit,
                          icon: Icon(Icons.edit_rounded, size: 16, color: palette.textMuted),
                          style: IconButton.styleFrom(
                            backgroundColor: palette.surfaceRaised,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Footer
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: palette.surfaceMuted.withValues(alpha: 0.5),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Last updated: recently',
                  style: TextStyle(fontSize: 10, color: palette.textMuted),
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: onEdit,
                      style: TextButton.styleFrom(
                        foregroundColor: palette.secondary,
                        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                      child: const Text('Edit Config'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => vm.removeMcpServer(server.id),
                      style: TextButton.styleFrom(
                        foregroundColor: palette.error,
                        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
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
                hintText: '{\n  "command": "node",\n  "args": ["..."]\n}',
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
