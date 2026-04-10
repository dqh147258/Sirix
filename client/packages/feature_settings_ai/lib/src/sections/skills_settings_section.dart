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

    return ListView(
      children: [
        AiSettingsSectionHeader(
          title: 'Skills',
          subtitle: 'Import local skill folders, decide whether they are active, and control whether their scripts may step outside the sandbox.',
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
        if (state.config.skills.isEmpty)
          const AiSettingsEmptyState(text: 'No skills configured.'),
        for (final skill in state.config.skills) ...[
          AiSettingsCard(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(skill.name, style: Theme.of(context).textTheme.titleMedium),
                    ),
                    IconButton(
                      onPressed: () async {
                        final edited = await _showSkillDialog(context, vm: vm, existing: skill);
                        if (edited != null) {
                          vm.upsertSkill(edited);
                        }
                      },
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      onPressed: () => vm.removeSkill(skill.id),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
                Text(
                  skill.path,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textSecondary,
                      ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AiSettingsChip(label: skill.id),
                    AiSettingsChip(
                      label: skill.enabled ? 'enabled' : 'disabled',
                    ),
                    AiSettingsChip(
                      label: skill.allowOutsideSandbox ? 'sandbox:outside' : 'sandbox:workspace',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    AiSettingsToggleTile(
                      title: 'Enabled',
                      value: skill.enabled,
                      onChanged: (value) => vm.upsertSkill(skill.copyWith(enabled: value)),
                    ),
                    AiSettingsToggleTile(
                      title: 'Allow Outside Sandbox',
                      subtitle: 'Use only for trusted local skills.',
                      width: 340,
                      value: skill.allowOutsideSandbox,
                      onChanged: (value) =>
                          vm.upsertSkill(skill.copyWith(allowOutsideSandbox: value)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
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
