import 'dart:io';

import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../settings_ui.dart';
import '../ai_settings_view_model.dart';

class SkillsSettingsSection extends StatelessWidget {
  const SkillsSettingsSection({
    super.key,
    required this.state,
    required this.vm,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final skills = state.visibleSkills;

    return ListView(
      children: [
        AiSettingsSectionHeader(
          title: 'Skills Management',
          subtitle: 'Configure and deploy computational capabilities for the orchestration layer. Manage sandbox permissions and runtime paths for your AI agents.',
          action: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final folder = await getDirectoryPath();
                  if (folder == null || folder.trim().isEmpty) {
                    return;
                  }
                  final validation = _validateSkillFolder(folder);
                  if (validation != null && context.mounted) {
                    await _showValidationDialog(context, validation);
                    return;
                  }
                  final name = _folderName(folder);
                  vm.upsertSkill(
                    SkillConfigModel(
                      id: vm.createStableId('skill'),
                      name: name,
                      path: folder,
                      enabled: true,
                      allowOutsideSandbox: false,
                    ),
                  );
                },
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Import Folder'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  final created = await _showSkillDialog(context, vm: vm, existing: null);
                  if (created != null) {
                    vm.upsertSkill(created);
                  }
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add Skill'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = constraints.maxWidth < 600 ? constraints.maxWidth : (constraints.maxWidth - 16) / 2;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final skill in skills)
                  SizedBox(
                    width: cardWidth,
                    child: _SkillGridCard(
                      skill: skill,
                      vm: vm,
                      sourceLabel: state.sourceLabelForResource(
                        workspaceOwned: state.workspaceOwnsSkill(skill.id),
                        globalOwned: state.globalOwnsSkill(skill.id),
                      ),
                      allowDelete:
                          !state.isWorkspaceScope || state.workspaceOwnsSkill(skill.id),
                      onEdit: () async {
                        final edited = await _showSkillDialog(context, vm: vm, existing: skill);
                        if (edited != null) {
                          vm.upsertSkill(edited);
                        }
                      },
                    ),
                  ),
                SizedBox(
                  width: cardWidth,
                  child: InkWell(
                    onTap: () async {
                      final created = await _showSkillDialog(context, vm: vm, existing: null);
                      if (created != null) {
                        vm.upsertSkill(created);
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      height: 250,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: palette.glassStroke,
                          style: BorderStyle.solid, 
                        ),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.transparent,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: palette.surfaceRaised,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.add_rounded, color: palette.textMuted),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Register New Skill',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'OR IMPORT FOLDER',
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 10,
                              fontFamily: 'JetBrains Mono',
                              letterSpacing: 1.2,
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

class _SkillGridCard extends StatelessWidget {
  const _SkillGridCard({
    required this.skill,
    required this.vm,
    required this.sourceLabel,
    required this.allowDelete,
    required this.onEdit,
  });

  final SkillConfigModel skill;
  final AiSettingsViewModel vm;
  final String? sourceLabel;
  final bool allowDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.glassStroke),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Area
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: palette.primaryBright.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(Icons.public_rounded, color: palette.primaryBright, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        skill.name,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: ${skill.id}',
                        style: TextStyle(
                          fontFamily: 'JetBrains Mono',
                          fontSize: 10,
                          color: palette.primaryBright.withValues(alpha: 0.7),
                          letterSpacing: 1.2,
                        ),
                      ),
                      if (sourceLabel != null && sourceLabel!.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        AiSettingsChip(label: sourceLabel!),
                      ],
                    ],
                  ),
                ),
                Switch(
                  value: skill.enabled,
                  onChanged: (val) => vm.upsertSkill(skill.copyWith(enabled: val)),
                  activeThumbColor: palette.primaryBright,
                ),
                PopupMenuButton<_SkillCardAction>(
                  icon: Icon(Icons.more_vert_rounded, color: palette.textMuted, size: 20),
                  color: palette.surfaceRaised,
                  onSelected: (action) {
                    // Run actions after the popup closes so edit/delete stays reliable.
                    switch (action) {
                      case _SkillCardAction.edit:
                        onEdit();
                        break;
                      case _SkillCardAction.delete:
                        vm.removeSkill(skill.id);
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: _SkillCardAction.edit,
                      child: Text('Edit Skill'),
                    ),
                    if (allowDelete)
                      PopupMenuItem(
                        value: _SkillCardAction.delete,
                        child: Text('Delete Skill', style: TextStyle(color: palette.error)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          
          // Execution Path
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'EXECUTION PATH',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: palette.textMuted,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                  ),
                  child: Text(
                    skill.path,
                    style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 11,
                      color: palette.secondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Allow Outside Sandbox
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: palette.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: palette.error.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: palette.error, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Allow Outside Sandbox',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 24,
                    child: Switch(
                      value: skill.allowOutsideSandbox,
                      onChanged: (val) => vm.upsertSkill(skill.copyWith(allowOutsideSandbox: val)),
                      activeThumbColor: palette.error,
                      inactiveThumbColor: palette.textMuted,
                      inactiveTrackColor: palette.surfaceMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _folderName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((item) => item.isNotEmpty).toList(growable: false);
  if (parts.isEmpty) {
    return 'Imported Skill';
  }
  return parts.last;
}

enum _SkillCardAction {
  edit,
  delete,
}

Future<SkillConfigModel?> _showSkillDialog(
  BuildContext context, {
  required AiSettingsViewModel vm,
  required SkillConfigModel? existing,
}) async {
  final idController = TextEditingController(text: existing?.id ?? vm.createStableId('skill'));
  final nameController = TextEditingController(text: existing?.name ?? 'New Skill');
  final pathController = TextEditingController(text: existing?.path ?? '');
  var enabled = existing?.enabled ?? true;
  var allowOutsideSandbox = existing?.allowOutsideSandbox ?? false;

  final submitted = await showAiSettingsDialog<SkillConfigModel>(
    context: context,
    title: existing == null ? 'Add Skill' : 'Edit Skill',
    subtitle: 'Point Sirix at a folder-based skill package. Enabled skills must include SKILL.md.',
    width: 600,
    child: StatefulBuilder(
      builder: (context, setState) {
        return AiSettingsFieldGroup(
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(labelText: 'Skill ID'),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Skill Name'),
            ),
            TextField(
              controller: pathController,
              decoration: const InputDecoration(labelText: 'Skill Path (folder)'),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                AiSettingsToggleTile(
                  title: 'Enabled',
                  value: enabled,
                  onChanged: (value) => setState(() => enabled = value),
                ),
                AiSettingsToggleTile(
                  title: 'Allow Outside Sandbox',
                  subtitle: 'For trusted skills only.',
                  width: 320,
                  value: allowOutsideSandbox,
                  onChanged: (value) => setState(() => allowOutsideSandbox = value),
                ),
              ],
            ),
          ],
        );
      },
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(
        onPressed: () async {
          final path = pathController.text.trim();
          final validation = enabled ? _validateSkillFolder(path) : null;
          if (validation != null) {
            await _showValidationDialog(context, validation);
            return;
          }

          if (!context.mounted) {
            return;
          }
          Navigator.of(context).pop(
            SkillConfigModel(
              id: idController.text.trim(),
              name: nameController.text.trim(),
              path: path,
              enabled: enabled,
              allowOutsideSandbox: allowOutsideSandbox,
            ),
          );
        },
        child: const Text('Save'),
      ),
    ],
  );

  return submitted;
}

String? _validateSkillFolder(String path) {
  final normalized = path.trim();
  if (normalized.isEmpty) {
    return 'Skill path cannot be empty.';
  }
  final directory = Directory(normalized);
  if (!directory.existsSync()) {
    return 'Skill folder does not exist: $normalized';
  }
  final skillMd = File('${directory.path}${Platform.pathSeparator}SKILL.md');
  if (!skillMd.existsSync()) {
    return 'Selected folder must contain SKILL.md.';
  }
  return null;
}

Future<void> _showValidationDialog(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      child: AiSettingsCard(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Invalid Skill Folder',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontFamily: 'Space Grotesk',
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 10),
            Text(message),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
