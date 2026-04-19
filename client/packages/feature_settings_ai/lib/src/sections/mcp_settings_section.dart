import 'dart:convert';

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
    final runtimeStatuses = <String, LocalMcpServerStatus>{
      for (final server in state.statusOverview?.mcp.servers ?? const <LocalMcpServerStatus>[])
        server.id: server,
    };
    final servers = state.config.mcpServers;
    final mcpGlobal = state.config.mcp;
    final activeCount = servers.where((server) => server.enabled).length;
    final healthyCount = runtimeStatuses.values.where((server) => server.healthy).length;
    final discoveredToolCount = runtimeStatuses.values.fold<int>(
      0,
      (sum, status) => sum + status.discoveredTools.length,
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        AiSettingsSectionHeader(
          title: 'MCP Servers',
          subtitle: 'Manage MCP transports, registered servers, and discovered child functions. Permission editing now lives in Permissions.',
          action: FilledButton.icon(
            onPressed: () async {
              final created = await _showMcpDialog(context, vm: vm, existing: null);
              if (created != null) {
                vm.upsertMcpServer(created);
              }
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add Server'),
          ),
        ),
        AiSettingsCard(
          // Keep the page focused on transport/server/discovery management only.
          // The compact overview replaces the old hero block so this page matches the denser AI Settings sections.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tileWidth = constraints.maxWidth < 860
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 16) / 2;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  AiSettingsToggleTile(
                    title: 'Enable MCP',
                    subtitle: 'Master switch for MCP integration across the runtime.',
                    value: mcpGlobal.enabled,
                    onChanged: (value) => vm.updateMcpGlobal(mcpGlobal.copyWith(enabled: value)),
                    width: tileWidth,
                  ),
                  AiSettingsToggleTile(
                    title: 'Allow STDIO Transport',
                    subtitle: 'Permit local command-based MCP servers to start.',
                    value: mcpGlobal.allowStdio,
                    onChanged: (value) => vm.updateMcpGlobal(mcpGlobal.copyWith(allowStdio: value)),
                    width: tileWidth,
                  ),
                  AiSettingsToggleTile(
                    title: 'Allow HTTP Transport',
                    subtitle: 'Permit remote or locally hosted HTTP MCP endpoints.',
                    value: mcpGlobal.allowHttp,
                    onChanged: (value) => vm.updateMcpGlobal(mcpGlobal.copyWith(allowHttp: value)),
                    width: tileWidth,
                  ),
                  _McpOverviewTile(
                    width: tileWidth,
                    icon: Icons.dns_rounded,
                    title: 'Registered Servers',
                    value: '${servers.length}',
                    subtitle: '$activeCount active · ${servers.length - activeCount} disabled',
                  ),
                  _McpOverviewTile(
                    width: tileWidth,
                    icon: Icons.hub_rounded,
                    title: 'Discovery Coverage',
                    value: '$discoveredToolCount',
                    subtitle: '$healthyCount healthy runtime probes',
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        if (servers.isEmpty)
          const AiSettingsEmptyState(
            text: 'No MCP servers registered yet. Add a server to configure transport payloads and discovery metadata.',
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = constraints.maxWidth < 960
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 16) / 2;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final server in servers)
                    SizedBox(
                      width: cardWidth,
                      child: _McpServerCard(
                        server: server,
                        runtimeStatus: runtimeStatuses[server.id],
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
                    child: _AddMcpServerCard(
                      onPressed: () async {
                        final created = await _showMcpDialog(context, vm: vm, existing: null);
                        if (created != null) {
                          vm.upsertMcpServer(created);
                        }
                      },
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

class _McpOverviewTile extends StatelessWidget {
  const _McpOverviewTile({
    required this.width,
    required this.icon,
    required this.title,
    required this.value,
    required this.subtitle,
  });

  final double width;
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: palette.primaryBright.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: palette.primaryBright, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: palette.textMuted,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontFamily: 'Space Grotesk',
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textSecondary,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AddMcpServerCard extends StatelessWidget {
  const _AddMcpServerCard({
    required this.onPressed,
  });

  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 252,
        decoration: BoxDecoration(
          color: palette.surfaceRaised.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.glassStroke),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: palette.surfaceRaised,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.add_rounded, color: palette.primaryBright, size: 28),
            ),
            const SizedBox(height: 14),
            Text(
              'Register New Server',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontFamily: 'Space Grotesk',
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Add another MCP endpoint without leaving the transport/discovery workflow.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _McpServerCard extends StatelessWidget {
  const _McpServerCard({
    required this.server,
    required this.runtimeStatus,
    required this.vm,
    required this.onEdit,
  });

  final McpServerConfigModel server;
  final LocalMcpServerStatus? runtimeStatus;
  final AiSettingsViewModel vm;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final isEnabled = server.enabled;
    final discoveredTools = runtimeStatus?.discoveredTools ?? const <LocalMcpServerToolStatus>[];
    final configMap = _tryParseJsonObject(server.jsonConfig);
    final transportLabel = _resolveTransportLabel(server, runtimeStatus, configMap);
    final endpointSummary = _resolveEndpointSummary(server, runtimeStatus, configMap);
    final healthLabel = _resolveHealthLabel(runtimeStatus);
    final healthColor = _resolveHealthColor(palette, runtimeStatus);
    final updatedLabel = _formatUpdatedAt(runtimeStatus?.updatedAt);

    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.glassStroke),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      foregroundDecoration: isEnabled
          ? null
          : BoxDecoration(
              color: Colors.black.withValues(alpha: 0.32),
              borderRadius: BorderRadius.circular(8),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: isEnabled
                            ? palette.primaryBright.withValues(alpha: 0.12)
                            : palette.surfaceMuted.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        isEnabled ? Icons.storage_rounded : Icons.cloud_off_rounded,
                        color: isEnabled ? palette.primaryBright : palette.textMuted,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.name,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontFamily: 'Space Grotesk',
                                  fontWeight: FontWeight.w700,
                                  color: isEnabled ? palette.textPrimary : palette.textMuted,
                                ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            server.id,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontFamily: 'JetBrains Mono',
                                  color: palette.textMuted,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          isEnabled ? 'ACTIVE' : 'DISABLED',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: isEnabled ? palette.primaryBright : palette.textMuted,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Switch(
                          value: isEnabled,
                          onChanged: (value) => vm.upsertMcpServer(server.copyWith(enabled: value)),
                          activeThumbColor: palette.primaryBright,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ServerMetaChip(label: 'Transport', value: transportLabel),
                    _ServerMetaChip(label: 'Runtime', value: healthLabel, accentColor: healthColor),
                    _ServerMetaChip(
                      label: 'Discovery',
                      value: discoveredTools.isEmpty ? 'No functions yet' : '${discoveredTools.length} functions',
                    ),
                    _ServerMetaChip(
                      label: 'Filters',
                      value: '${server.enabledTools.length} allow · ${server.disabledTools.length} block',
                    ),
                  ],
                ),
                if (endpointSummary != null) ...[
                  const SizedBox(height: 12),
                  _InlineSummaryRow(
                    icon: Icons.route_rounded,
                    label: 'Endpoint',
                    value: endpointSummary,
                  ),
                ],
                const SizedBox(height: 8),
                _InlineSummaryRow(
                  icon: Icons.schedule_rounded,
                  label: 'Last probe',
                  value: updatedLabel,
                ),
                if (runtimeStatus?.error case final error?) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: palette.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: palette.error.withValues(alpha: 0.25)),
                    ),
                    child: Text(
                      error,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.error,
                          ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Divider(height: 1, color: palette.glassStroke),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'DISCOVERED FUNCTIONS',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: palette.textMuted,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.6,
                            ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _showDiscoveredToolsInfoDialog(
                        context,
                        server: server,
                        runtimeStatus: runtimeStatus,
                      ),
                      icon: const Icon(Icons.info_outline_rounded, size: 16),
                      label: const Text('Info'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (discoveredTools.isEmpty)
                  Text(
                    'No child functions discovered yet. Connect the server and open Info to review runtime details when they become available.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final previewTools = discoveredTools.take(4).toList(growable: false);
                      final extraCount = discoveredTools.length - previewTools.length;
                      final maxChipWidth = constraints.maxWidth < 420
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 8) / 2;

                      // Long function titles used to expand uncontrolled inside the old header row.
                      // These preview chips now constrain width and ellipsize text so discovery stays readable without overflow.
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final tool in previewTools)
                            _ToolPreviewChip(
                              label: _toolLabel(tool),
                              tooltip: _toolTooltip(tool),
                              maxWidth: maxChipWidth,
                            ),
                          if (extraCount > 0)
                            _ToolPreviewChip(
                              label: '+$extraCount more',
                              tooltip: '${discoveredTools.length} discovered child functions',
                              maxWidth: maxChipWidth,
                            ),
                        ],
                      );
                    },
                  ),
                const SizedBox(height: 16),
                Text(
                  'CONFIG PREVIEW',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: palette.textMuted,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 96),
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: palette.glassStroke),
                  ),
                  child: Stack(
                    children: [
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(14, 14, 54, 14),
                        child: SelectableText(
                          server.jsonConfig.trim().isEmpty ? '{}' : server.jsonConfig.trim(),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'JetBrains Mono',
                                color: palette.textSecondary,
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
                          tooltip: 'Edit server',
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: palette.surfaceMuted.withValues(alpha: 0.5),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Manage server transport/config here. Use Permissions for approval policy changes.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: onEdit,
                  child: const Text('Edit'),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => vm.removeMcpServer(server.id),
                  style: TextButton.styleFrom(
                    foregroundColor: palette.error,
                  ),
                  child: const Text('Remove'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerMetaChip extends StatelessWidget {
  const _ServerMetaChip({
    required this.label,
    required this.value,
    this.accentColor,
  });

  final String label;
  final String value;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final resolvedAccent = accentColor ?? palette.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            TextSpan(
              text: value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: resolvedAccent,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineSummaryRow extends StatelessWidget {
  const _InlineSummaryRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: palette.textMuted),
        ),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: palette.textMuted,
                fontWeight: FontWeight.w700,
              ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textSecondary,
                ),
          ),
        ),
      ],
    );
  }
}

class _ToolPreviewChip extends StatelessWidget {
  const _ToolPreviewChip({
    required this.label,
    required this.tooltip,
    required this.maxWidth,
  });

  final String label;
  final String tooltip;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Tooltip(
      message: tooltip,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: palette.surfaceMuted.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
                fontFamily: 'JetBrains Mono',
              ),
        ),
      ),
    );
  }
}

Future<void> _showDiscoveredToolsInfoDialog(
  BuildContext context, {
  required McpServerConfigModel server,
  required LocalMcpServerStatus? runtimeStatus,
}) {
  final discoveredTools = runtimeStatus?.discoveredTools ?? const <LocalMcpServerToolStatus>[];

  // This dialog is intentionally read-only so the MCP page can expose discovery details
  // without drifting back into permission editing responsibilities.
  return showAiSettingsDialog<void>(
    context: context,
    title: '${server.name} · MCP Info',
    subtitle: 'Review runtime-discovered child functions for this server. Title, id, and description are shown exactly as the runtime reported them.',
    width: 760,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _DialogMetaChip(label: 'Server ID', value: server.id),
            _DialogMetaChip(
              label: 'Transport',
              value: _resolveTransportLabel(server, runtimeStatus, _tryParseJsonObject(server.jsonConfig)),
            ),
            _DialogMetaChip(label: 'Functions', value: '${discoveredTools.length}'),
          ],
        ),
        const SizedBox(height: 16),
        if (discoveredTools.isEmpty)
          const AiSettingsEmptyState(
            text: 'No discovered child functions are available yet for this MCP server. Once the runtime probe succeeds, detailed function metadata will appear here.',
          )
        else
          Column(
            children: [
              for (var index = 0; index < discoveredTools.length; index += 1) ...[
                _DiscoveredToolDetailCard(tool: discoveredTools[index]),
                if (index != discoveredTools.length - 1) const SizedBox(height: 12),
              ],
            ],
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}

class _DialogMetaChip extends StatelessWidget {
  const _DialogMetaChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(999),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            TextSpan(
              text: value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveredToolDetailCard extends StatelessWidget {
  const _DiscoveredToolDetailCard({
    required this.tool,
  });

  final LocalMcpServerToolStatus tool;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _toolLabel(tool),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFamily: 'Space Grotesk',
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            tool.id,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'JetBrains Mono',
                  color: palette.primaryBright,
                ),
          ),
          const SizedBox(height: 10),
          Text(
            tool.description?.trim().isNotEmpty == true
                ? tool.description!.trim()
                : 'No description was published for this child function.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: tool.description?.trim().isNotEmpty == true
                      ? palette.textSecondary
                      : palette.textMuted,
                  height: 1.45,
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

  // Preserve the stored approval mode so transport/discovery edits here never mutate permission semantics.
  final preservedApprovalMode = existing?.approvalMode ?? ApprovalMode.allow;

  final submitted = await showAiSettingsDialog<bool>(
    context: context,
    title: existing == null ? 'Add MCP Server' : 'Edit MCP Server',
    subtitle: 'Define the MCP transport payload, tool discovery filters, and server metadata for this management view.',
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
            AiSettingsToggleTile(
              title: 'Enabled',
              subtitle: 'Disable a server here without removing its saved transport payload.',
              value: enabled,
              onChanged: (value) => setState(() => enabled = value),
              width: double.infinity,
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
    approvalMode: preservedApprovalMode,
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

Map<String, dynamic>? _tryParseJsonObject(String raw) {
  if (raw.trim().isEmpty) {
    return null;
  }

  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {
    // Keep the management page resilient even when the saved JSON is temporarily invalid.
  }

  return null;
}

String _resolveTransportLabel(
  McpServerConfigModel server,
  LocalMcpServerStatus? runtimeStatus,
  Map<String, dynamic>? configMap,
) {
  final runtimeTransport = runtimeStatus?.transport.trim();
  if (runtimeTransport != null && runtimeTransport.isNotEmpty) {
    return runtimeTransport.toUpperCase();
  }

  final configuredTransport = configMap?['transport']?.toString().trim();
  if (configuredTransport != null && configuredTransport.isNotEmpty) {
    return configuredTransport.toUpperCase();
  }

  if ((configMap?['url'] ?? configMap?['base_url'] ?? configMap?['baseUrl']) != null) {
    return 'HTTP';
  }

  if ((configMap?['command'] ?? configMap?['cmd']) != null) {
    return 'STDIO';
  }

  return server.jsonConfig.trim().isEmpty ? 'UNSET' : 'CUSTOM';
}

String? _resolveEndpointSummary(
  McpServerConfigModel server,
  LocalMcpServerStatus? runtimeStatus,
  Map<String, dynamic>? configMap,
) {
  final url = (configMap?['url'] ?? configMap?['base_url'] ?? configMap?['baseUrl'])?.toString().trim();
  if (url != null && url.isNotEmpty) {
    return url;
  }

  final command = (configMap?['command'] ?? configMap?['cmd'])?.toString().trim();
  if (command != null && command.isNotEmpty) {
    final args = (configMap?['args'] as List<dynamic>? ?? const <dynamic>[])
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .join(' ');
    return args.isEmpty ? command : '$command $args';
  }

  if (runtimeStatus?.title.trim().isNotEmpty == true) {
    return runtimeStatus!.title.trim();
  }

  if (server.jsonConfig.trim().isNotEmpty) {
    return 'JSON transport payload configured';
  }

  return null;
}

String _resolveHealthLabel(LocalMcpServerStatus? runtimeStatus) {
  if (runtimeStatus == null) {
    return 'Pending probe';
  }
  if (!runtimeStatus.enabled) {
    return 'Disabled';
  }
  if (runtimeStatus.active && runtimeStatus.healthy) {
    return 'Healthy';
  }
  if (runtimeStatus.active) {
    return 'Active';
  }
  if (runtimeStatus.error?.trim().isNotEmpty == true) {
    return 'Error';
  }
  return 'Inactive';
}

Color _resolveHealthColor(SirixTheme palette, LocalMcpServerStatus? runtimeStatus) {
  if (runtimeStatus == null) {
    return palette.textSecondary;
  }
  if (!runtimeStatus.enabled) {
    return palette.textMuted;
  }
  if (runtimeStatus.active && runtimeStatus.healthy) {
    return palette.primaryBright;
  }
  if (runtimeStatus.error?.trim().isNotEmpty == true) {
    return palette.error;
  }
  return palette.secondary;
}

String _formatUpdatedAt(DateTime? value) {
  if (value == null) {
    return 'Waiting for runtime discovery';
  }

  final local = value.toLocal();
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _toolLabel(LocalMcpServerToolStatus tool) {
  final title = tool.title.trim();
  if (title.isNotEmpty) {
    return title;
  }
  final id = tool.id.trim();
  return id.isEmpty ? 'Unnamed function' : id;
}

String _toolTooltip(LocalMcpServerToolStatus tool) {
  final description = tool.description?.trim();
  if (description != null && description.isNotEmpty) {
    return '${_toolLabel(tool)}\n${tool.id}\n$description';
  }
  return '${_toolLabel(tool)}\n${tool.id}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
