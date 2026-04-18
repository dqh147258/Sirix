import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart'
    show Terminal, TerminalController, TerminalTheme, TerminalThemes, TerminalView;

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'terminal_state.dart';
import 'terminal_view_model.dart';

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({
    super.key,
    required this.accessToken,
    this.deviceId,
    this.sessionId,
    this.allowCreate = true,
    this.showHeader = true,
    this.compact = false,
    this.fullBleed = false,
  });

  final String accessToken;
  final String? deviceId;
  final String? sessionId;
  final bool allowCreate;
  final bool showHeader;
  final bool compact;
  final bool fullBleed;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final TerminalTheme _theme = TerminalThemes.defaultTheme;
  final FocusNode _focusNode = FocusNode(debugLabel: 'shared-terminal');
  final Map<String, TerminalController> _terminalControllers = <String, TerminalController>{};
  late TerminalPageConfig _config;

  @override
  void initState() {
    super.initState();
    _config = _buildConfig();
    final viewModel = ref.read(terminalViewModelProvider(_config).notifier);
    viewModel.updateConfig(_config);
    Future.microtask(() => viewModel.load());
  }

  @override
  void didUpdateWidget(covariant TerminalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextConfig = _buildConfig();
    final viewModel = ref.read(terminalViewModelProvider(nextConfig).notifier);
    viewModel.updateConfig(nextConfig);
    if (_config == nextConfig) {
      _config = nextConfig;
      return;
    }

    _config = nextConfig;
    Future.microtask(() => viewModel.load(force: true));
  }

  @override
  void dispose() {
    _focusNode.dispose();
    for (final controller in _terminalControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TerminalPageConfig _buildConfig() {
    return TerminalPageConfig(
      accessToken: widget.accessToken,
      deviceId: widget.deviceId,
      sessionId: widget.sessionId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;
    final state = ref.watch(terminalViewModelProvider(_config));
    final viewModel = ref.read(terminalViewModelProvider(_config).notifier);
    final horizontalInset = widget.fullBleed ? 0.0 : 16.0;
    final bottomInset = widget.fullBleed ? 0.0 : 16.0;
    final activeTerminal = state.activeTerminal;
    final activeTerminalId = state.activeTerminalId;
    final terminal = viewModel.terminalFor(activeTerminalId);
    final terminalController = _terminalControllerFor(activeTerminalId);
    final approvalRequest = state.activeApprovalRequest;
    final statusLabel = activeTerminal?.state.toUpperCase() ?? l10n.idle.toUpperCase();
    final canCreate = widget.allowCreate && widget.deviceId != null;

    _disposeInactiveTerminalControllers(state.terminals.map((item) => item.id));

    return Column(
      children: [
        if (widget.showHeader)
          Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalInset,
              16,
              horizontalInset,
              widget.compact ? 10 : 14,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.terminalPageTitle,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 26),
                      ),
                      if (!widget.compact) ...[
                        const SizedBox(height: 6),
                        Text(
                          l10n.sharedTerminalHint,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _ActionIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: l10n.refresh,
                  onPressed: () => unawaited(viewModel.refresh()),
                ),
                if (canCreate) ...[
                  const SizedBox(width: 8),
                  _ActionIconButton(
                    icon: Icons.add_rounded,
                    tooltip: l10n.createTerminal,
                    onPressed: () => unawaited(viewModel.createTerminal()),
                  ),
                ],
                const SizedBox(width: 8),
                _ActionIconButton(
                  icon: Icons.close_rounded,
                  tooltip: l10n.disconnectSession,
                  onPressed: () => unawaited(viewModel.closeActiveTerminal()),
                ),
              ],
            ),
          ),
        if (state.errorMessage != null)
          Padding(
            padding: EdgeInsets.fromLTRB(horizontalInset, 0, horizontalInset, 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: palette.error.withValues(alpha: 0.24)),
              ),
              child: Text(
                state.errorMessage!,
                style: TextStyle(color: palette.error),
              ),
            ),
          ),
        Container(
          margin: EdgeInsets.symmetric(horizontal: horizontalInset),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          height: 42,
          decoration: BoxDecoration(
            color: palette.surface.withValues(alpha: 0.88),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border(
              top: BorderSide(color: palette.glassStroke),
              left: BorderSide(color: palette.glassStroke),
              right: BorderSide(color: palette.glassStroke),
            ),
          ),
          child: state.loading
              ? const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: state.terminals.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 4),
                        itemBuilder: (context, index) {
                          final item = state.terminals[index];
                          return _TerminalTab(
                            summary: item,
                            selected: item.id == state.activeTerminalId,
                            onTap: () => viewModel.attachTerminal(item.id),
                            onClose: () => unawaited(viewModel.closeTerminal(item.id)),
                          );
                        },
                      ),
                    ),
                    if (canCreate)
                      IconButton(
                        onPressed: () => unawaited(viewModel.createTerminal()),
                        icon: const Icon(Icons.add, size: 18),
                        splashRadius: 18,
                      ),
                  ],
                ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(horizontalInset, 0, horizontalInset, bottomInset),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF0A0D10),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
                border: Border(
                  left: BorderSide(color: palette.glassStroke),
                  right: BorderSide(color: palette.glassStroke),
                  bottom: BorderSide(color: palette.glassStroke),
                ),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        if (state.terminals.isEmpty && !state.loading)
                          Positioned.fill(
                            // The dashboard embeds TerminalPage in a split
                            // panel, so the terminal viewport can temporarily
                            // shrink to a very short height before any session
                            // is created. Filling the available area here lets
                            // the empty-state widget inspect the real viewport
                            // height and switch to a denser layout instead of
                            // overflowing a loosely sized Stack child.
                            child: _TerminalEmptyState(
                              canCreate: canCreate,
                              compact: widget.compact,
                            ),
                          ),
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: state.terminals.isEmpty,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                              child: terminal == null
                                  ? const SizedBox.shrink()
                                  : TerminalView(
                                      terminal,
                                      key: ValueKey(activeTerminalId),
                                      controller: terminalController,
                                      theme: _theme,
                                      focusNode: _focusNode,
                                      autofocus: true,
                                      backgroundOpacity: 0,
                                    ),
                            ),
                          ),
                        ),
                        if (state.connecting)
                          Positioned(
                            top: 14,
                            right: 14,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: palette.surface.withValues(alpha: 0.84),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: palette.glassStroke),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            ),
                          ),
                        if (approvalRequest != null)
                          Positioned(
                            top: 14,
                            left: 14,
                            child: _ApprovalRequestCard(
                              request: approvalRequest,
                              onAllowOnce: () => unawaited(
                                viewModel.resolveApprovalRequest(
                                  request: approvalRequest,
                                  decision: 'allow',
                                  scope: 'once',
                                ),
                              ),
                              onAllowSession: () => unawaited(
                                viewModel.resolveApprovalRequest(
                                  request: approvalRequest,
                                  decision: 'allow',
                                  scope: 'session',
                                ),
                              ),
                              onDeny: () => unawaited(
                                viewModel.resolveApprovalRequest(
                                  request: approvalRequest,
                                  decision: 'deny',
                                  scope: 'deny',
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (terminalController == null)
                    _TerminalFooter(
                      activeTerminal: activeTerminal,
                      compact: widget.compact,
                      statusLabel: statusLabel,
                      hasSelection: false,
                      onCopySelection: null,
                    )
                  else
                    ListenableBuilder(
                      listenable: terminalController,
                      builder: (context, _) => _TerminalFooter(
                        activeTerminal: activeTerminal,
                        compact: widget.compact,
                        statusLabel: statusLabel,
                        hasSelection: terminalController.selection != null,
                        onCopySelection: terminal == null
                            ? null
                            : () => _copySelection(
                                  terminal: terminal,
                                  controller: terminalController,
                                ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  TerminalController? _terminalControllerFor(String? terminalId) {
    if (terminalId == null || terminalId.isEmpty) {
      return null;
    }

    return _terminalControllers.putIfAbsent(terminalId, TerminalController.new);
  }

  void _disposeInactiveTerminalControllers(Iterable<String> terminalIds) {
    final activeIds = terminalIds.toSet();
    final staleIds = _terminalControllers.keys
        .where((terminalId) => !activeIds.contains(terminalId))
        .toList(growable: false);
    for (final terminalId in staleIds) {
      // Each terminal tab owns an independent controller so selection ranges
      // cannot leak across buffers. Dispose controllers as tabs disappear to
      // avoid keeping stale anchors alive after the terminal session is closed.
      _terminalControllers.remove(terminalId)?.dispose();
    }
  }

  Future<void> _copySelection({
    required Terminal terminal,
    required TerminalController controller,
  }) async {
    final selection = controller.selection;
    if (selection == null) {
      return;
    }

    // Keep an explicit copy affordance in the shared terminal footer so
    // desktop users are not forced to remember terminal-specific shortcuts.
    final text = terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
  }
}

class _ApprovalRequestCard extends StatelessWidget {
  const _ApprovalRequestCard({
    required this.request,
    required this.onAllowOnce,
    required this.onAllowSession,
    required this.onDeny,
  });

  final TerminalApprovalRequest request;
  final VoidCallback onAllowOnce;
  final VoidCallback onAllowSession;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF131B20),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.warning.withValues(alpha: 0.28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 26,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Approval Required',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                request.capabilityKey,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontFamily: 'JetBrains Mono',
                      color: palette.warning,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                '${request.agentId} · ${request.modelId}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                      fontFamily: 'JetBrains Mono',
                    ),
              ),
              if (request.cwd.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  request.cwd,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                      ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: onAllowOnce,
                    child: const Text('Allow Once'),
                  ),
                  OutlinedButton(
                    onPressed: onAllowSession,
                    child: const Text('Allow Session'),
                  ),
                  TextButton(
                    onPressed: onDeny,
                    child: const Text('Deny'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionIconButton extends StatelessWidget {
  const _ActionIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: palette.surfaceRaised.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.glassStroke),
          ),
          child: Icon(icon, size: 20),
        ),
      ),
    );
  }
}

class _TerminalTab extends StatelessWidget {
  const _TerminalTab({
    required this.summary,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final TerminalSessionSummary summary;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? palette.surfaceRaised : Colors.transparent,
          border: selected
              ? Border(
                  left: BorderSide(color: palette.primaryBright, width: 2),
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal_rounded,
              size: 14,
              color: selected ? palette.primaryBright : palette.textMuted,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                summary.title.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? palette.textPrimary : palette.textSecondary,
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            if (summary.isHostedTerminal) ...[
              const SizedBox(width: 6),
              _TerminalSourceBadge(selected: selected),
            ],
            const SizedBox(width: 4),
            Tooltip(
              message: context.l10n.disconnectSession,
              child: InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: selected ? palette.textPrimary : palette.textMuted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalSourceBadge extends StatelessWidget {
  const _TerminalSourceBadge({
    required this.selected,
  });

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (selected ? palette.primaryBright : palette.textMuted).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (selected ? palette.primaryBright : palette.textMuted).withValues(alpha: 0.24),
        ),
      ),
      child: Text(
        'HOST',
        style: TextStyle(
          color: selected ? palette.primaryBright : palette.textSecondary,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _TerminalEmptyState extends StatelessWidget {
  const _TerminalEmptyState({
    required this.canCreate,
    required this.compact,
  });

  final bool canCreate;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight;
        final dense = compact || (maxHeight.isFinite && maxHeight < 140);
        final ultraCompact = maxHeight.isFinite && maxHeight < 96;
        final headline = canCreate ? l10n.noTerminalSession : l10n.terminalStreamUnavailable;
        final detail = canCreate ? l10n.noTerminalSessionHint : l10n.terminalTargetMissing;
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!ultraCompact) ...[
              Icon(
                Icons.terminal_rounded,
                size: dense ? 30 : 42,
                color: palette.textMuted,
              ),
              SizedBox(height: dense ? 8 : 12),
            ],
            Text(
              headline,
              maxLines: ultraCompact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: dense ? 15 : null,
                    color: palette.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            SizedBox(height: ultraCompact ? 4 : (dense ? 6 : 10)),
            Text(
              detail,
              maxLines: ultraCompact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: dense ? 12 : null,
                    color: palette.textSecondary,
                    height: dense ? 1.25 : null,
                  ),
            ),
          ],
        );

        return SingleChildScrollView(
          padding: EdgeInsets.all(ultraCompact ? 12 : (dense ? 16 : 24)),
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: maxHeight.isFinite ? maxHeight : 0,
            ),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

class _TerminalFooter extends StatelessWidget {
  const _TerminalFooter({
    required this.activeTerminal,
    required this.compact,
    required this.statusLabel,
    required this.hasSelection,
    required this.onCopySelection,
  });

  final TerminalSessionSummary? activeTerminal;
  final bool compact;
  final String statusLabel;
  final bool hasSelection;
  final VoidCallback? onCopySelection;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;

    return Container(
      height: compact ? 28 : 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF11161C),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
        border: Border(top: BorderSide(color: palette.glassStroke)),
      ),
      child: Row(
        children: [
          _StatusText(
            color: palette.primaryBright,
            text: l10n.terminalStable,
          ),
          const SizedBox(width: 16),
          const _StatusText(text: 'UTF-8'),
          const SizedBox(width: 16),
          _StatusText(
            text: activeTerminal == null
                ? '--'
                : 'COL ${activeTerminal!.cols}  ROW ${activeTerminal!.rows}',
          ),
          const Spacer(),
          _FooterActionText(
            label: compact ? 'COPY' : 'COPY SELECTION',
            enabled: hasSelection && onCopySelection != null,
            onTap: onCopySelection,
          ),
          const SizedBox(width: 16),
          _StatusText(text: statusLabel),
        ],
      ),
    );
  }
}

class _FooterActionText extends StatelessWidget {
  const _FooterActionText({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? palette.primaryBright : palette.textMuted.withValues(alpha: 0.45),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({
    required this.text,
    this.color,
  });

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Text(
      text,
      style: TextStyle(
        color: color ?? palette.textMuted,
        fontSize: 10,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.2,
      ),
    );
  }
}
