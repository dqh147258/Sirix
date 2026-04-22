import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart'
    show
        Terminal,
        TerminalController,
        TerminalStyle,
        TerminalTheme,
        TerminalThemes,
        TerminalView;

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
    this.trailingTabActions = const <TerminalToolbarAction>[],
  });

  final String accessToken;
  final String? deviceId;
  final String? sessionId;
  final bool allowCreate;
  final bool showHeader;
  final bool compact;
  final bool fullBleed;
  final List<TerminalToolbarAction> trailingTabActions;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class TerminalToolbarAction {
  const TerminalToolbarAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final TerminalTheme _theme = TerminalThemes.defaultTheme;
  final FocusNode _focusNode = FocusNode(debugLabel: 'shared-terminal');
  final Map<String, TerminalController> _terminalControllers = <String, TerminalController>{};
  final Map<String, ScrollController> _terminalScrollControllers = <String, ScrollController>{};
  final Set<String> _pendingControllerCleanupIds = <String>{};
  late TerminalPageConfig _config;
  String? _lastAutoFocusedTerminalId;
  bool _controllerCleanupScheduled = false;

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
    for (final controller in _terminalScrollControllers.values) {
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
    final authority = viewModel.authorityFor(activeTerminalId);
    final terminalController = _terminalControllerFor(activeTerminalId);
    final terminalScrollController = _terminalScrollControllerFor(
      terminalId: activeTerminalId,
      viewModel: viewModel,
    );
    final terminalStyle = _terminalStyleForContext(context);
    final approvalRequest = state.activeApprovalRequest;
    final statusLabel = activeTerminal?.state.toUpperCase() ?? l10n.idle.toUpperCase();
    final canCreate = widget.allowCreate && widget.deviceId != null;
    final toolbarActions = <TerminalToolbarAction>[
      if (canCreate)
        TerminalToolbarAction(
          icon: Icons.add_rounded,
          tooltip: l10n.createTerminal,
          onPressed: () => unawaited(viewModel.createTerminal()),
        ),
      ...widget.trailingTabActions,
    ];

    _disposeInactiveTerminalControllers(state.terminals.map((item) => item.id));
    _maybeRequestTerminalFocus(
      activeTerminalId: activeTerminalId,
      hasTerminal: terminal != null,
    );

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
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(minHeight: 48),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        // The reviewed dashboard keeps terminal tabs mandatory
                        // even in narrow layouts. Wrapping avoids hiding tabs
                        // behind horizontal scrolling once the terminal area is
                        // resized shorter or narrower.
                        constraints: const BoxConstraints(maxHeight: 96),
                        child: SingleChildScrollView(
                          physics: const ClampingScrollPhysics(),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final item in state.terminals)
                                _TerminalTab(
                                  summary: item,
                                  selected: item.id == state.activeTerminalId,
                                  onTap: () => viewModel.attachTerminal(item.id),
                                  onClose: () => unawaited(viewModel.closeTerminal(item.id)),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (toolbarActions.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final action in toolbarActions)
                            _TerminalToolbarButton(action: action),
                        ],
                      ),
                    ],
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
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (_) => _requestTerminalFocus(),
                            child: IgnorePointer(
                              ignoring: state.terminals.isEmpty,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                                child: terminal == null
                                    ? const SizedBox.shrink()
                                    : LayoutBuilder(
                                        builder: (context, constraints) {
                                          _maybeReportViewportGeometry(
                                            viewModel: viewModel,
                                            terminalId: activeTerminalId,
                                            constraints: constraints,
                                            terminalStyle: terminalStyle,
                                          );
                                          final authorityCols = authority?.cols ?? 0;
                                          final terminalWidth = _terminalContentWidth(
                                            context: context,
                                            terminalStyle: terminalStyle,
                                            cols: authorityCols > 0
                                                ? authorityCols
                                                : activeTerminal?.cols ?? 120,
                                            minWidth: constraints.maxWidth,
                                          );
                                          return ScrollConfiguration(
                                            behavior: const MaterialScrollBehavior(),
                                            child: SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              child: SizedBox(
                                                width: terminalWidth,
                                                height: constraints.maxHeight,
                                                child: RepaintBoundary(
                                                  // 远端桌面画面和 Terminal 会同时刷新；将
                                                  // xterm 视图包进独立的 repaint boundary，
                                                  // 可减少父布局重建时对终端栅格的连带重绘，
                                                  // 降低移动端“闪一下 / 重叠一下”的体感。
                                                  child: TerminalView(
                                                    terminal,
                                                    key: ValueKey(activeTerminalId),
                                                    controller: terminalController,
                                                    scrollController: terminalScrollController,
                                                    theme: _theme,
                                                    textStyle: terminalStyle,
                                                    focusNode: _focusNode,
                                                    autofocus: true,
                                                    autoResize: false,
                                                    // Keep the viewport background owned by
                                                    // the surrounding workspace panel. CLI
                                                    // color blocks (including Codex/Sirix
                                                    // TUI highlights) should come from the
                                                    // terminal escape stream itself rather
                                                    // than from a forced global fill color.
                                                    backgroundOpacity: 0,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
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
                              onResolve: (decision, scope, prefix) => unawaited(
                                viewModel.resolveApprovalRequest(
                                  request: approvalRequest,
                                  decision: decision,
                                  scope: scope,
                                  prefix: prefix,
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

  void _maybeRequestTerminalFocus({
    required String? activeTerminalId,
    required bool hasTerminal,
  }) {
    if (!hasTerminal || activeTerminalId == null || activeTerminalId.isEmpty) {
      _lastAutoFocusedTerminalId = null;
      return;
    }
    if (_lastAutoFocusedTerminalId == activeTerminalId && _focusNode.hasFocus) {
      return;
    }
    _lastAutoFocusedTerminalId = activeTerminalId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _requestTerminalFocus();
    });
  }

  TerminalStyle _terminalStyleForContext(BuildContext context) {
    final isMobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.fuchsia => false,
    };
    return TerminalStyle(
      fontSize: isMobile ? 12 : 13,
      height: 1.15,
    );
  }

  double _terminalContentWidth({
    required BuildContext context,
    required TerminalStyle terminalStyle,
    required int cols,
    required double minWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'W',
        style: TextStyle(
          fontSize: terminalStyle.fontSize,
          height: terminalStyle.height,
          fontFamily: terminalStyle.fontFamily,
          fontFamilyFallback: terminalStyle.fontFamilyFallback,
        ),
      ),
      textDirection: Directionality.of(context),
    )..layout();
    final cellWidth = painter.width <= 0 ? 8.0 : painter.width;
    return ((cols * cellWidth + 12).clamp(minWidth, double.infinity) as num).toDouble();
  }

  void _maybeReportViewportGeometry({
    required TerminalViewModel viewModel,
    required String? terminalId,
    required BoxConstraints constraints,
    required TerminalStyle terminalStyle,
  }) {
    if (terminalId == null || !constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
      return;
    }
    final probe = TextPainter(
      text: TextSpan(
        text: 'W',
        style: TextStyle(
          fontSize: terminalStyle.fontSize,
          height: terminalStyle.height,
          fontFamily: terminalStyle.fontFamily,
          fontFamilyFallback: terminalStyle.fontFamilyFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final cellWidth = probe.width <= 0 ? 8.0 : probe.width;
    final cellHeight = probe.height <= 0 ? terminalStyle.fontSize : probe.height;
    final cols = ((constraints.maxWidth / cellWidth).floor().clamp(20, 400) as num).toInt();
    final rows = ((constraints.maxHeight / cellHeight).floor().clamp(10, 200) as num).toInt();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      viewModel.queueResize(
        terminalId: terminalId,
        cols: cols,
        rows: rows,
      );
    });
  }

  TerminalController? _terminalControllerFor(String? terminalId) {
    if (terminalId == null || terminalId.isEmpty) {
      return null;
    }

    return _terminalControllers.putIfAbsent(terminalId, TerminalController.new);
  }

  ScrollController? _terminalScrollControllerFor({
    required String? terminalId,
    required TerminalViewModel viewModel,
  }) {
    if (terminalId == null || terminalId.isEmpty) {
      return null;
    }

    return _terminalScrollControllers.putIfAbsent(terminalId, () {
      final controller = ScrollController();
      controller.addListener(() {
        if (!controller.hasClients) {
          return;
        }
        viewModel.onTerminalVerticalScroll(
          terminalId: terminalId,
          extentBefore: controller.position.extentBefore,
        );
      });
      return controller;
    });
  }

  void _disposeInactiveTerminalControllers(Iterable<String> terminalIds) {
    final activeIds = terminalIds.toSet();
    final staleIds = _terminalControllers.keys
        .where((terminalId) => !activeIds.contains(terminalId))
        .toList(growable: false);
    if (staleIds.isEmpty) {
      return;
    }
    _pendingControllerCleanupIds.addAll(staleIds);
    if (_controllerCleanupScheduled) {
      return;
    }
    _controllerCleanupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controllerCleanupScheduled = false;
      if (!mounted || _pendingControllerCleanupIds.isEmpty) {
        _pendingControllerCleanupIds.clear();
        return;
      }

      final currentState = ref.read(terminalViewModelProvider(_config));
      final activeIds = currentState.terminals.map((terminal) => terminal.id).toSet();
      final cleanupIds = _pendingControllerCleanupIds.toList(growable: false);
      _pendingControllerCleanupIds.clear();
      for (final terminalId in cleanupIds) {
        if (activeIds.contains(terminalId)) {
          continue;
        }
        // TerminalView 在本帧完成前仍可能持有旧 controller；延后到 post-frame
        // 再释放，避免 render object 还在 attach 时读到已 dispose 的 controller。
        _terminalControllers.remove(terminalId)?.dispose();
        _terminalScrollControllers.remove(terminalId)?.dispose();
      }
    });
  }

  void _requestTerminalFocus() {
    if (!mounted || _focusNode.hasFocus || !_focusNode.canRequestFocus) {
      return;
    }

    // The dashboard redesign embeds TerminalPage inside additional split-panel
    // chrome. Some desktop builds no longer transfer focus reliably on the
    // first frame after a tab/terminal switch, so request focus explicitly on
    // terminal activation and direct viewport clicks. Avoid doing this on
    // ordinary rebuilds so other controls can keep focus when the user moves
    // away from the terminal intentionally.
    FocusScope.of(context).requestFocus(_focusNode);
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

class _ApprovalRequestCard extends StatefulWidget {
  const _ApprovalRequestCard({
    required this.request,
    required this.onResolve,
  });

  final TerminalApprovalRequest request;
  final void Function(String decision, String scope, String? prefix) onResolve;

  @override
  State<_ApprovalRequestCard> createState() => _ApprovalRequestCardState();
}

class _ApprovalRequestCardState extends State<_ApprovalRequestCard> {
  String? _selectedPrefix;

  @override
  void initState() {
    super.initState();
    _selectedPrefix = widget.request.shellPrefixCandidates.isNotEmpty
        ? widget.request.shellPrefixCandidates.first
        : null;
  }

  @override
  void didUpdateWidget(covariant _ApprovalRequestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.requestId != widget.request.requestId ||
        oldWidget.request.shellPrefixCandidates != widget.request.shellPrefixCandidates) {
      _selectedPrefix = widget.request.shellPrefixCandidates.isNotEmpty
          ? widget.request.shellPrefixCandidates.first
          : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final isShellRequest = widget.request.approvalKind == 'shell';

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
                widget.request.capabilityKey,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontFamily: 'JetBrains Mono',
                      color: palette.warning,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.request.agentId} · ${widget.request.modelId}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                      fontFamily: 'JetBrains Mono',
                    ),
              ),
              if (widget.request.cwd.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  widget.request.cwd,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                      ),
                ),
              ],
              if (isShellRequest &&
                  (widget.request.shellCommand?.trim().isNotEmpty ?? false)) ...[
                const SizedBox(height: 10),
                Text(
                  widget.request.shellCommand!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'JetBrains Mono',
                        color: palette.textPrimary,
                      ),
                ),
              ],
              if (isShellRequest &&
                  widget.request.shellPrefixCandidates.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Shell Prefix',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                      ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final prefix in widget.request.shellPrefixCandidates)
                      ChoiceChip(
                        label: SizedBox(
                          width: 300,
                          child: Text(
                            prefix,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        selected: _selectedPrefix == prefix,
                        onSelected: (_) => setState(() {
                          _selectedPrefix = prefix;
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final scope in widget.request.supportedScopes)
                    FilledButton(
                      onPressed: () => widget.onResolve(
                        'allow',
                        scope,
                        _prefixForScope(scope),
                      ),
                      child: Text(_approvalActionLabel('allow', scope)),
                    ),
                  for (final scope in widget.request.supportedScopes)
                    OutlinedButton(
                      onPressed: () => widget.onResolve(
                        'deny',
                        scope,
                        _prefixForScope(scope),
                      ),
                      child: Text(_approvalActionLabel('deny', scope)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _prefixForScope(String scope) {
    if (widget.request.approvalKind != 'shell') {
      return null;
    }
    switch (scope.trim().toLowerCase()) {
      case 'once':
        return null;
      case 'session':
      case 'workspace':
      case 'global':
        return _selectedPrefix;
      default:
        return null;
    }
  }
}

String _approvalActionLabel(String decision, String scope) {
  final normalizedScope = scope.trim().toLowerCase();
  final scopeLabel = switch (normalizedScope) {
    'once' => 'Once',
    'session' => 'Session',
    'workspace' => 'Workspace',
    'global' => 'Global',
    _ => normalizedScope,
  };
  return '${decision == 'allow' ? 'Allow' : 'Deny'} $scopeLabel';
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

class _TerminalToolbarButton extends StatelessWidget {
  const _TerminalToolbarButton({
    required this.action,
  });

  final TerminalToolbarAction action;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Tooltip(
      message: action.tooltip,
      child: InkWell(
        onTap: action.onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: palette.surfaceRaised.withValues(alpha: 0.74),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.glassStroke),
          ),
          child: Icon(
            action.icon,
            size: 18,
            color: palette.textPrimary,
          ),
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
    final metricsText = activeTerminal == null
        ? '--'
        : 'COL ${activeTerminal!.cols}  ROW ${activeTerminal!.rows}';
    final copyLabel = compact ? 'COPY' : 'COPY SELECTION';

    return Container(
      constraints: BoxConstraints(minHeight: compact ? 32 : 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF11161C),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
        border: Border(top: BorderSide(color: palette.glassStroke)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrowCompact = compact && constraints.maxWidth < 430;
          if (narrowCompact) {
            // 移动端 workspace 模式宽度较窄，底栏若仍然一行塞下全部状态文案，
            // 会在右下角产生 overflow 警告条。窄宽度时改成双行信息布局，
            // 保留关键状态，同时避免 footer 把终端可用高度继续压缩得抖动。
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _StatusText(
                        color: palette.primaryBright,
                        text: l10n.terminalStable,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const _StatusText(text: 'UTF-8'),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _StatusText(text: statusLabel),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(child: _StatusText(text: metricsText)),
                    const SizedBox(width: 8),
                    _FooterActionText(
                      label: copyLabel,
                      enabled: hasSelection && onCopySelection != null,
                      onTap: onCopySelection,
                    ),
                  ],
                ),
              ],
            );
          }

          return Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: _StatusText(
                        color: palette.primaryBright,
                        text: l10n.terminalStable,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const _StatusText(text: 'UTF-8'),
                    const SizedBox(width: 16),
                    Expanded(child: _StatusText(text: metricsText)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _FooterActionText(
                label: copyLabel,
                enabled: hasSelection && onCopySelection != null,
                onTap: onCopySelection,
              ),
              const SizedBox(width: 16),
              Flexible(child: _StatusText(text: statusLabel)),
            ],
          );
        },
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
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color ?? palette.textMuted,
        fontSize: 10,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.2,
      ),
    );
  }
}
