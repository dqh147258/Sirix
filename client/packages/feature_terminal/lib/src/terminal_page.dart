import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'terminal_view_model.dart';

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({
    super.key,
    required this.accessToken,
    this.deviceId,
    this.allowCreate = true,
    this.showHeader = true,
    this.compact = false,
  });

  final String accessToken;
  final String? deviceId;
  final bool allowCreate;
  final bool showHeader;
  final bool compact;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final TerminalTheme _theme = TerminalThemes.defaultTheme;
  final FocusNode _focusNode = FocusNode(debugLabel: 'shared-terminal');
  final Map<String, Terminal> _terminalCache = <String, Terminal>{};
  StreamSubscription<TerminalUiEvent>? _uiSubscription;
  late TerminalPageConfig _config;

  @override
  void initState() {
    super.initState();
    _config = _buildConfig();
    _bindViewModel(load: true);
  }

  @override
  void didUpdateWidget(covariant TerminalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextConfig = _buildConfig();
    if (_config == nextConfig) {
      return;
    }

    _config = nextConfig;
    _terminalCache.clear();
    _bindViewModel(load: true);
  }

  @override
  void dispose() {
    final subscription = _uiSubscription;
    _uiSubscription = null;
    unawaited(subscription?.cancel());
    _focusNode.dispose();
    super.dispose();
  }

  TerminalPageConfig _buildConfig() {
    return TerminalPageConfig(
      accessToken: widget.accessToken,
      deviceId: widget.deviceId,
      allowCreate: widget.allowCreate,
    );
  }

  Terminal _createTerminal(String terminalId) {
    final terminal = Terminal(maxLines: 10000);
    _bindTerminalCallbacks(terminal, terminalId);
    return terminal;
  }

  Terminal _terminalFor(String terminalId) {
    return _terminalCache.putIfAbsent(terminalId, () => _createTerminal(terminalId));
  }

  void _bindTerminalCallbacks(Terminal terminal, String terminalId) {
    terminal.onOutput = (data) {
      ref.read(terminalViewModelProvider(_config).notifier).queueInput(
            terminalId: terminalId,
            data: data,
          );
    };
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      ref
          .read(terminalViewModelProvider(_config).notifier)
          .queueResize(
            terminalId: terminalId,
            cols: width,
            rows: height,
          );
    };
  }

  void _bindViewModel({
    required bool load,
  }) {
    final previousSubscription = _uiSubscription;
    _uiSubscription = null;
    unawaited(previousSubscription?.cancel());
    final viewModel = ref.read(terminalViewModelProvider(_config).notifier);
    _uiSubscription = viewModel.events.listen(_handleUiEvent);

    if (load) {
      Future.microtask(() => viewModel.load());
    }
  }

  void _handleUiEvent(TerminalUiEvent event) {
    switch (event.type) {
      case TerminalUiEventType.snapshot:
        final terminal = _createTerminal(event.terminalId);
        if (event.text.isNotEmpty) {
          terminal.write(event.text);
        }
        _terminalCache[event.terminalId] = terminal;
        if (event.terminalId == ref.read(terminalViewModelProvider(_config)).activeTerminalId &&
            mounted) {
          setState(() {});
        }
        break;
      case TerminalUiEventType.output:
        final terminal = _terminalFor(event.terminalId);
        terminal.write(event.text);
        break;
    }
  }

  void _pruneTerminalCache(Iterable<String> terminalIds) {
    final allowed = terminalIds.toSet();
    _terminalCache.removeWhere((key, _) => !allowed.contains(key));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;
    final state = ref.watch(terminalViewModelProvider(_config));
    final viewModel = ref.read(terminalViewModelProvider(_config).notifier);
    _pruneTerminalCache(state.terminals.map((item) => item.id));
    final activeTerminal = state.activeTerminal;
    final activeTerminalId = state.activeTerminalId;
    final terminal = activeTerminalId == null ? null : _terminalFor(activeTerminalId);
    final statusLabel = activeTerminal?.state.toUpperCase() ?? l10n.idle.toUpperCase();
    final canCreate = widget.allowCreate && widget.deviceId != null;

    return Column(
      children: [
        if (widget.showHeader)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, widget.compact ? 10 : 14),
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
          margin: const EdgeInsets.symmetric(horizontal: 16),
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
                          _TerminalEmptyState(canCreate: canCreate),
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
                      ],
                    ),
                  ),
                  _TerminalFooter(
                    activeTerminal: activeTerminal,
                    compact: widget.compact,
                    statusLabel: statusLabel,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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

class _TerminalEmptyState extends StatelessWidget {
  const _TerminalEmptyState({required this.canCreate});

  final bool canCreate;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal_rounded,
              size: 42,
              color: palette.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              canCreate ? l10n.terminalCapabilityHint : l10n.terminalStreamUnavailable,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: palette.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalFooter extends StatelessWidget {
  const _TerminalFooter({
    required this.activeTerminal,
    required this.compact,
    required this.statusLabel,
  });

  final TerminalSessionSummary? activeTerminal;
  final bool compact;
  final String statusLabel;

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
          _StatusText(text: statusLabel),
        ],
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
