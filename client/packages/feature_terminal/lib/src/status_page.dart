import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

class StatusPage extends ConsumerStatefulWidget {
  const StatusPage({
    super.key,
    this.showHeader = true,
  });

  final bool showHeader;

  @override
  ConsumerState<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends ConsumerState<StatusPage> {
  Future<LocalStatusOverview>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<LocalStatusOverview> _load() {
    return ref.read(desktopLocalClientProvider).getStatusOverview();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return FutureBuilder<LocalStatusOverview>(
      future: _future,
      builder: (context, snapshot) {
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (widget.showHeader)
              _StatusHeader(
                loading: snapshot.connectionState == ConnectionState.waiting,
                onRefresh: () => setState(() => _future = _load()),
              ),
            if (snapshot.hasError)
              _StatusCard(
                child: Text(
                  'Status unavailable: ${snapshot.error}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: palette.error,
                      ),
                ),
              )
            else if (!snapshot.hasData)
              const _StatusCard(
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _RuntimeSection(data: snapshot.data!),
              const SizedBox(height: 16),
              _McpSection(data: snapshot.data!),
            ],
          ],
        );
      },
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.loading,
    required this.onRefresh,
  });

  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Status',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Runtime health, MCP status, backend connectivity, and AI session activity.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.sirix.textMuted,
                      ),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: loading ? null : onRefresh,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

class _RuntimeSection extends StatelessWidget {
  const _RuntimeSection({required this.data});

  final LocalStatusOverview data;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 900;
        final cards = [
          _MetricCard(
            title: 'Backend',
            rows: [
              ('Event Stream', data.backend.connected ? 'Connected' : 'Disconnected'),
              ('Last Healthy', _formatDateTime(data.backend.lastHealthyAt)),
            ],
          ),
          _MetricCard(
            title: 'Runtime',
            rows: [
              ('Local WS Port', '${data.runtime.localWsPort}'),
              ('Desktop Connections', '${data.runtime.desktopClientConnections}'),
              ('Logging', data.runtime.loggingEnabled ? 'Enabled' : 'Disabled'),
            ],
          ),
          _MetricCard(
            title: 'Workspace',
            rows: [
              ('AI Sessions', '${data.ai.activeSessions}'),
              ('Local Terminals', '${data.terminals.activeTerminals}'),
              (
                'Standalone Terminal',
                data.terminals.standalonePageDeprecated ? 'Deprecated' : 'Active',
              ),
            ],
          ),
        ];

        if (stacked) {
          return Column(
            children: [
              for (var index = 0; index < cards.length; index++) ...[
                cards[index],
                if (index != cards.length - 1) const SizedBox(height: 16),
              ],
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < cards.length; index++) ...[
              Expanded(child: cards[index]),
              if (index != cards.length - 1) const SizedBox(width: 16),
            ],
          ],
        );
      },
    );
  }
}

class _McpSection extends StatelessWidget {
  const _McpSection({required this.data});

  final LocalStatusOverview data;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return _StatusCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MCP Status',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Green means the MCP probe succeeded. Red means the desktop-side probe failed or the configuration is invalid.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.textMuted,
                          ),
                    ),
                  ],
                ),
              ),
              _SummaryPill(
                label: '${data.mcp.activeCount} healthy / ${data.mcp.errorCount} error',
                color: data.mcp.errorCount == 0 ? palette.primaryBright : palette.error,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (data.mcp.servers.isEmpty)
            Text(
              'No MCP servers configured.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                  ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final server in data.mcp.servers)
                  _McpBadge(server: server),
              ],
            ),
          const SizedBox(height: 14),
          Text(
            'Last probe: ${_formatDateTime(data.mcp.lastProbeAt)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.surfaceMuted.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Standalone Terminal page is deprecated. Use Dashboard for terminal work; Status replaces the old standalone slot.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.rows,
  });

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return _StatusCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < rows.length; index++) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    rows[index].$1,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  rows[index].$2,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            if (index != rows.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _McpBadge extends StatelessWidget {
  const _McpBadge({required this.server});

  final LocalMcpServerStatus server;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final color = server.healthy ? palette.primaryBright : palette.error;

    return Tooltip(
      message: server.error == null || server.error!.trim().isEmpty
          ? '${server.title} (${server.transport})'
          : '${server.title} (${server.transport})\n${server.error}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: palette.surfaceMuted.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              server.title,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  const _SummaryPill({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.sirix.surfaceRaised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.sirix.glassStroke),
      ),
      child: child,
    );
  }
}

String _formatDateTime(DateTime? value) {
  if (value == null) {
    return 'Unknown';
  }
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute:$second';
}
