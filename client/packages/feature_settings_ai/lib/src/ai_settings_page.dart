import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';

import 'ai_settings_state.dart';
import 'ai_settings_view_model.dart';
import 'settings_ui.dart';
import 'sections/agent_settings_section.dart';
import 'sections/cli_settings_section.dart';
import 'sections/mcp_settings_section.dart';
import 'sections/provider_settings_section.dart';
import 'sections/shell_rules_settings_section.dart';
import 'sections/skills_settings_section.dart';

class AiSettingsPage extends ConsumerStatefulWidget {
  const AiSettingsPage({
    super.key,
    this.scope = AiSettingsScope.global,
  });

  final AiSettingsScope scope;

  @override
  ConsumerState<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends ConsumerState<AiSettingsPage> {
  Timer? _noticeTimer;
  String? _visibleNoticeMessage;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(aiSettingsViewModelProvider(widget.scope).notifier).load();
    });
  }

  @override
  void didUpdateWidget(covariant AiSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      Future.microtask(() {
        ref.read(aiSettingsViewModelProvider(widget.scope).notifier).load(force: true);
      });
    }
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final provider = aiSettingsViewModelProvider(widget.scope);
    final state = ref.watch(provider);
    final vm = ref.read(provider.notifier);

    ref.listen<AiSettingsState>(provider, (previous, next) {
      final nextNotice = next.noticeMessage?.trim();
      if (previous?.noticeMessage == next.noticeMessage) {
        return;
      }

      _noticeTimer?.cancel();
      if (nextNotice == null || nextNotice.isEmpty) {
        if (_visibleNoticeMessage != null && mounted) {
          setState(() => _visibleNoticeMessage = null);
        }
        return;
      }

      // Save success is a transient acknowledgement rather than a persistent
      // status banner. Keep it visible long enough to be noticed, then fade it
      // out locally so the settings screen can return to a steady layout.
      if (mounted) {
        setState(() => _visibleNoticeMessage = nextNotice);
      }
      _noticeTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted || _visibleNoticeMessage != nextNotice) {
          return;
        }
        setState(() => _visibleNoticeMessage = null);
      });
    });

    final canPersist = !state.saving && (!state.isWorkspaceScope || state.hasSelectedWorkspace);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Keep the desktop shell anchored to the left; when space shrinks,
          // collapse the nav into icon-only mode instead of switching to chips.
          final useCollapsedNav = constraints.maxWidth < 1280;
          final navWidth = useCollapsedNav ? 88.0 : 260.0;
          final contentMaxWidth = constraints.maxWidth - navWidth - 18;
          final isTightContent = contentMaxWidth < 900;
          final nav = _NavPane(
            state: state,
            vm: vm,
            mode: useCollapsedNav ? _NavPaneMode.collapsed : _NavPaneMode.full,
          );
          final content = Container(
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    gradient: LinearGradient(
                      colors: [
                        palette.surfaceRaised.withValues(alpha: 0.96),
                        palette.surface.withValues(alpha: 0.9),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border(
                      bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (state.isWorkspaceScope && !isTightContent)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _SettingsHeaderIntro(state: state),
                            ),
                            const SizedBox(width: 16),
                            SizedBox(
                              width: contentMaxWidth.clamp(320.0, 980.0) * 0.46,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _WorkspaceTargetSummaryBar(
                                    state: state,
                                    onOpen: state.loading
                                        ? null
                                        : () => _showWorkspaceTargetDialog(),
                                  ),
                                  const SizedBox(height: 14),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: _HeaderActions(
                                      state: state,
                                      vm: vm,
                                      canPersist: canPersist,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      else
                        Wrap(
                          spacing: 14,
                          runSpacing: 14,
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: isTightContent
                                  ? (contentMaxWidth - 44).clamp(260.0, 520.0)
                                  : 520,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _SettingsHeaderIntro(state: state),
                                  if (state.isWorkspaceScope) ...[
                                    const SizedBox(height: 14),
                                    _WorkspaceTargetSummaryBar(
                                      state: state,
                                      onOpen: state.loading
                                          ? null
                                          : () => _showWorkspaceTargetDialog(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            _HeaderActions(
                              state: state,
                              vm: vm,
                              canPersist: canPersist,
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SizeTransition(
                        sizeFactor: animation,
                        axisAlignment: -1,
                        child: child,
                      ),
                    );
                  },
                  child: _BannerStack(
                    key: ValueKey('${state.errorMessage}::$_visibleNoticeMessage'),
                    errorMessage: state.errorMessage,
                    noticeMessage: _visibleNoticeMessage,
                    errorColor: palette.error,
                    noticeColor: palette.primaryBright,
                  ),
                ),
                Expanded(
                  child: state.loading
                      ? const Center(child: CircularProgressIndicator())
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                          child: _SectionBody(state: state),
                        ),
                ),
              ],
            ),
          );

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: navWidth, child: nav),
              const SizedBox(width: 18),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showWorkspaceTargetDialog() async {
    final provider = aiSettingsViewModelProvider(widget.scope);
    final vm = ref.read(provider.notifier);
    vm.updateWorkspaceSearchQuery('');
    await showAiSettingsDialog<void>(
      context: context,
      title: 'Workspace Target',
      subtitle:
          'Choose a recent workspace or select a directory from the file system. Selecting any option closes this dialog immediately.',
      width: 760,
      actions: const [],
      child: Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(provider);
          final vm = ref.read(provider.notifier);
          return _WorkspaceTargetDialogBody(state: state, vm: vm);
        },
      ),
    );
  }
}

class _WorkspaceTargetSummaryBar extends StatelessWidget {
  const _WorkspaceTargetSummaryBar({
    required this.state,
    required this.onOpen,
  });

  final AiSettingsState state;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.glassStroke),
      ),
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
                width: 540,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.selectedWorkspaceRoot ?? 'No workspace selected',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontFamily: 'JetBrains Mono',
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    if (state.workspaceStatusMessage != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        state.workspaceStatusMessage!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Open'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsHeaderIntro extends StatelessWidget {
  const _SettingsHeaderIntro({
    required this.state,
  });

  final AiSettingsState state;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _titleForScope(state.scope),
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontFamily: 'Space Grotesk',
              ),
        ),
        const SizedBox(height: 6),
        Text(
          _subtitleForScope(state.scope),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _chipsForState(state)
              .map((label) => AiSettingsChip(label: label))
              .toList(growable: false),
        ),
      ],
    );
  }
}

class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.state,
    required this.vm,
    required this.canPersist,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;
  final bool canPersist;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        OutlinedButton.icon(
          onPressed: state.loading ? null : () => vm.load(force: true),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Reload'),
        ),
        FilledButton.icon(
          onPressed: canPersist ? vm.save : null,
          icon: state.saving
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: palette.surface,
                  ),
                )
              : const Icon(Icons.save_rounded),
          label: Text(state.saving ? 'Saving...' : 'Save Changes'),
        ),
      ],
    );
  }
}

class _WorkspaceTargetDialogBody extends StatelessWidget {
  const _WorkspaceTargetDialogBody({
    required this.state,
    required this.vm,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final filtered = state.filteredRecentWorkspaces;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Recent Workspaces',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Space Grotesk',
                    ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final folder = await getDirectoryPath();
                if (folder == null || folder.trim().isEmpty || !context.mounted) {
                  return;
                }
                await vm.selectWorkspace(folder);
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              icon: const Icon(Icons.create_new_folder_rounded),
              label: const Text('Select from file system'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextFormField(
          key: ValueKey('workspace-search-${state.scope.name}'),
          initialValue: state.workspaceSearchQuery,
          onChanged: vm.updateWorkspaceSearchQuery,
          decoration: const InputDecoration(
            labelText: 'Search recent workspaces',
            hintText: 'Filter by folder name or full path',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 14),
        if (state.recentWorkspaces.isEmpty)
          const AiSettingsEmptyState(
            text: 'No recent workspaces yet. Use Select from file system to choose a workspace directory.',
          )
        else if (filtered.isEmpty)
          const AiSettingsEmptyState(
            text: 'No recent workspaces match the current search query.',
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final workspace = filtered[index];
                final isSelected = workspace.rootPath == state.selectedWorkspaceRoot;
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      await vm.selectWorkspace(workspace.rootPath);
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: Ink(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? palette.surfaceMuted.withValues(alpha: 0.52)
                            : palette.surfaceRaised,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? palette.primaryBright.withValues(alpha: 0.42)
                              : palette.glassStroke,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.workspaces_rounded,
                              color: isSelected ? palette.primaryBright : palette.textMuted,
                              size: 18,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    workspace.label,
                                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    workspace.rootPath,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: palette.textMuted,
                                          fontFamily: 'JetBrains Mono',
                                        ),
                                  ),
                                  if (workspace.subtitle != null &&
                                      workspace.subtitle!.trim().isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      workspace.subtitle!,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: palette.textSecondary,
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                AiSettingsChip(
                                  label: workspace.hasSirixConfig
                                      ? _sceneWorkspaceDirName
                                      : 'No $_sceneWorkspaceDirName',
                                ),
                                if (workspace.hasCodexConfig)
                                  const AiSettingsChip(label: '.codex detected'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _NavPane extends StatelessWidget {
  const _NavPane({
    required this.state,
    required this.vm,
    required this.mode,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;
  final _NavPaneMode mode;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final isCollapsed = mode == _NavPaneMode.collapsed;
    final items = [
      (AiSettingsSection.cli, 'CLI', 'Global prompt and runtime defaults', Icons.code_rounded),
      (AiSettingsSection.providers, 'Providers', 'Model backends and capabilities', Icons.hub_rounded),
      (AiSettingsSection.skills, 'Skills', 'Imported folders and sandbox reach', Icons.auto_awesome_rounded),
      (AiSettingsSection.mcp, 'MCP', 'External tools, transports, and gating', Icons.extension_rounded),
      (AiSettingsSection.agents, 'Agents', 'Profiles, approvals, and tool routing', Icons.smart_toy_rounded),
      (
        AiSettingsSection.permissions,
        'Permissions',
        'Approval defaults and shell authorization policy',
        Icons.rule_folder_rounded,
      ),
    ].where((item) => state.visibleSections.contains(item.$1)).toList(growable: false);

    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.glassStroke),
      ),
      child: ListView(
        padding: EdgeInsets.fromLTRB(isCollapsed ? 8 : 14, 16, isCollapsed ? 8 : 14, 16),
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(isCollapsed ? 0 : 6, 2, isCollapsed ? 0 : 6, 16),
            child: isCollapsed
                ? Tooltip(
                    message: state.isWorkspaceScope ? 'Workspace Settings' : 'Global Settings',
                    child: Icon(
                      state.isWorkspaceScope
                          ? Icons.folder_special_rounded
                          : Icons.dashboard_customize_rounded,
                      color: palette.primaryBright,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.isWorkspaceScope ? 'Workspace Surface' : 'Control Surface',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontFamily: 'Space Grotesk',
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        state.isWorkspaceScope
                            ? 'Workspace Settings only exposes local Skills, MCP, Agents, and Permissions so global CLI/provider state stays centralized.'
                            : 'A desktop-native shell for local AI runtime controls, aligned with the rest of the Sirix workspace.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                            ),
                      ),
                    ],
                  ),
          ),
          for (final item in items)
            _NavItem(
              icon: item.$4,
              label: item.$2,
              subtitle: item.$3,
              active: state.selectedSection == item.$1,
              collapsed: isCollapsed,
              onTap: () => vm.selectSection(item.$1),
            ),
        ],
      ),
    );
  }
}

class _SectionBody extends ConsumerWidget {
  const _SectionBody({required this.state});

  final AiSettingsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.read(aiSettingsViewModelProvider(state.scope).notifier);

    if (state.isWorkspaceScope && !state.hasSelectedWorkspace) {
      return const AiSettingsEmptyState(
        text: 'Choose a recent workspace or open a directory to start editing workspace-local Skills, MCP, Agents, and Permissions.',
      );
    }

    return switch (state.selectedSection) {
      AiSettingsSection.cli => CliSettingsSection(state: state, vm: vm),
      AiSettingsSection.providers => ProviderSettingsSection(state: state, vm: vm),
      AiSettingsSection.skills => SkillsSettingsSection(state: state, vm: vm),
      AiSettingsSection.mcp => McpSettingsSection(state: state, vm: vm),
      AiSettingsSection.agents => AgentSettingsSection(state: state, vm: vm),
      AiSettingsSection.permissions => ShellRulesSettingsSection(state: state, vm: vm),
    };
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.active,
    required this.collapsed,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool active;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Tooltip(
            message: label,
            waitDuration: const Duration(milliseconds: 250),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: collapsed ? 12 : 16,
                vertical: 12,
              ),
              decoration: BoxDecoration(
                color: active
                    ? palette.surfaceMuted.withValues(alpha: 0.7)
                    : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: active ? palette.primaryBright : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: collapsed
                  ? Center(
                      child: Icon(
                        icon,
                        size: 20,
                        color: active ? palette.primaryBright : palette.textMuted,
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 20,
                          color: active ? palette.primaryBright : palette.textMuted,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: TextStyle(
                                  color: active ? palette.primaryBright : palette.textSecondary,
                                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                                  fontSize: 12,
                                  letterSpacing: 0.5,
                                  fontFamily: 'Inter',
                                ).copyWith(
                                  fontFamily: 'Space Grotesk',
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontSize: 10,
                                      color: palette.textMuted,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _NavPaneMode {
  full,
  collapsed,
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.text,
  });

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(text),
      ),
    );
  }
}

class _BannerStack extends StatelessWidget {
  const _BannerStack({
    super.key,
    required this.errorMessage,
    required this.noticeMessage,
    required this.errorColor,
    required this.noticeColor,
  });

  final String? errorMessage;
  final String? noticeMessage;
  final Color errorColor;
  final Color noticeColor;

  @override
  Widget build(BuildContext context) {
    if (errorMessage == null && noticeMessage == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (errorMessage != null) _Banner(color: errorColor, text: errorMessage!),
        if (noticeMessage != null) _Banner(color: noticeColor, text: noticeMessage!),
      ],
    );
  }
}

String _titleForScope(AiSettingsScope scope) {
  return switch (scope) {
    AiSettingsScope.global => 'Global Settings',
    AiSettingsScope.workspace => 'Workspace Settings',
  };
}

String _subtitleForScope(AiSettingsScope scope) {
  return switch (scope) {
    AiSettingsScope.global =>
      'Manage global AI runtime behavior, provider routing, skill access, MCP transport, and agent permissions for the entire desktop runtime.',
    AiSettingsScope.workspace =>
      'Manage workspace-local Skills, MCP, Agents, and Permissions overrides without duplicating global CLI or Provider configuration.',
  };
}

List<String> _chipsForState(AiSettingsState state) {
  final effectiveSource = state.effective?.workspaceSource;
  if (!state.isWorkspaceScope) {
    return [
      'Desktop Runtime',
      effectiveSource == null
          ? '~/' '$_sceneGlobalDirName/config.toml'
          : 'effective: $effectiveSource',
    ];
  }

  return [
    'Workspace Local',
    if (effectiveSource != null) 'effective: $effectiveSource',
    if (effectiveSource == null && state.selectedWorkspaceRoot != null) 'effective: global defaults',
  ];
}

const _sceneGlobalDirName =
    String.fromEnvironment('SIRIX_SCENE', defaultValue: 'debug') == 'release'
    ? '.sirix'
    : '.sirix-debug';

const _sceneWorkspaceDirName = _sceneGlobalDirName;
