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
import 'sections/skills_settings_section.dart';

class AiSettingsPage extends ConsumerStatefulWidget {
  const AiSettingsPage({super.key});

  @override
  ConsumerState<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends ConsumerState<AiSettingsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(aiSettingsViewModelProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final state = ref.watch(aiSettingsViewModelProvider);
    final vm = ref.read(aiSettingsViewModelProvider.notifier);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 1100;
          final nav = _NavPane(state: state, vm: vm, compact: isNarrow);
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
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: isNarrow ? constraints.maxWidth - 44 : 480,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'AI Settings',
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'Space Grotesk',
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Manage local AI runtime behavior, provider routing, skill access, MCP transport, and agent permissions from one control surface.',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: palette.textSecondary,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                const AiSettingsChip(label: 'Desktop Runtime'),
                                AiSettingsChip(
                                  label: state.effective?.workspaceSource == null
                                      ? '~/.sirix/config.toml'
                                      : 'effective: ${state.effective!.workspaceSource}',
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton.icon(
                            onPressed: state.loading ? null : () => vm.load(force: true),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Reload'),
                          ),
                          FilledButton.icon(
                            onPressed: state.saving ? null : vm.save,
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
                      ),
                    ],
                  ),
                ),
                if (state.errorMessage != null)
                  _Banner(color: palette.error, text: state.errorMessage!),
                if (state.noticeMessage != null)
                  _Banner(color: palette.primaryBright, text: state.noticeMessage!),
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

          if (isNarrow) {
            return Column(
              children: [
                nav,
                const SizedBox(height: 14),
                Expanded(child: content),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 260, child: nav),
              const SizedBox(width: 18),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }
}

class _NavPane extends StatelessWidget {
  const _NavPane({
    required this.state,
    required this.vm,
    required this.compact,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final items = [
      (AiSettingsSection.cli, 'CLI', 'Global prompt and runtime defaults', Icons.code_rounded),
      (AiSettingsSection.providers, 'Providers', 'Model backends and capabilities', Icons.hub_rounded),
      (AiSettingsSection.skills, 'Skills', 'Imported folders and sandbox reach', Icons.auto_awesome_rounded),
      (AiSettingsSection.mcp, 'MCP', 'External tools, transports, and gating', Icons.extension_rounded),
      (AiSettingsSection.agents, 'Agents', 'Profiles, approvals, and tool routing', Icons.smart_toy_rounded),
    ];

    if (compact) {
      return AiSettingsCard(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in items)
              ChoiceChip(
                label: Text(item.$2),
                selected: state.selectedSection == item.$1,
                onSelected: (_) => vm.selectSection(item.$1),
              ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Control Surface',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontFamily: 'Space Grotesk',
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'A desktop-native shell for local AI runtime controls, aligned with the rest of the Sirix workspace.',
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
    final vm = ref.read(aiSettingsViewModelProvider.notifier);

    return switch (state.selectedSection) {
      AiSettingsSection.cli => CliSettingsSection(state: state, vm: vm),
      AiSettingsSection.providers => ProviderSettingsSection(state: state, vm: vm),
      AiSettingsSection.skills => SkillsSettingsSection(state: state, vm: vm),
      AiSettingsSection.mcp => McpSettingsSection(state: state, vm: vm),
      AiSettingsSection.agents => AgentSettingsSection(state: state, vm: vm),
    };
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: active
                  ? palette.primary.withValues(alpha: 0.14)
                  : palette.surface.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(18),
              border: active
                  ? Border.all(color: palette.primaryBright.withValues(alpha: 0.24))
                  : Border.all(color: Colors.white.withValues(alpha: 0.03)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: active
                        ? palette.primary.withValues(alpha: 0.18)
                        : palette.surfaceMuted.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: active ? palette.primaryBright : palette.textMuted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: active ? palette.primaryBright : palette.textPrimary,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
