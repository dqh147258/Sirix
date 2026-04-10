import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../settings_ui.dart';
import '../ai_settings_view_model.dart';

class ProviderSettingsSection extends StatelessWidget {
  const ProviderSettingsSection({
    super.key,
    required this.state,
    required this.vm,
  });

  final AiSettingsState state;
  final AiSettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        AiSettingsSectionHeader(
          title: 'Providers',
          subtitle: 'Register model backends, define their capabilities, and curate the exact models agents can route to.',
          action: FilledButton.icon(
            onPressed: () async {
              final created = await _showProviderDialog(
                context,
                vm: vm,
                existing: null,
              );
              if (created != null) {
                vm.upsertProvider(created);
              }
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add Provider'),
          ),
        ),
        if (state.config.providers.isEmpty)
          const AiSettingsEmptyState(text: 'No providers configured.'),
        for (final provider in state.config.providers) ...[
          _ProviderCard(
            provider: provider,
            onToggleEnabled: (value) => vm.upsertProvider(provider.copyWith(enabled: value)),
            onEdit: () async {
              final edited = await _showProviderDialog(
                context,
                vm: vm,
                existing: provider,
              );
              if (edited != null) {
                vm.upsertProvider(edited);
              }
            },
            onDelete: () => vm.removeProvider(provider.id),
            onAddModel: () async {
              final created = await _showModelDialog(
                context,
                vm: vm,
                provider: provider,
                existing: null,
              );
              if (created != null) {
                vm.upsertModel(providerId: provider.id, model: created);
              }
            },
            onEditModel: (model) async {
              final edited = await _showModelDialog(
                context,
                vm: vm,
                provider: provider,
                existing: model,
              );
              if (edited != null) {
                vm.upsertModel(providerId: provider.id, model: edited);
              }
            },
            onDeleteModel: (modelId) => vm.removeModel(providerId: provider.id, modelId: modelId),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.onToggleEnabled,
    required this.onEdit,
    required this.onDelete,
    required this.onAddModel,
    required this.onEditModel,
    required this.onDeleteModel,
  });

  final AiProviderConfig provider;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onAddModel;
  final ValueChanged<AiModelConfig> onEditModel;
  final ValueChanged<String> onDeleteModel;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return AiSettingsCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(provider.name, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${provider.id} · ${_enumName(provider.kind)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.textMuted,
                            fontFamily: 'JetBrains Mono',
                          ),
                    ),
                  ],
                ),
              ),
              Container(
                margin: const EdgeInsets.only(right: 8),
                child: Switch(value: provider.enabled, onChanged: onToggleEnabled),
              ),
              IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_outlined)),
              IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AiSettingsChip(label: provider.id),
              AiSettingsChip(label: _enumName(provider.kind)),
              AiSettingsChip(label: provider.enabled ? 'enabled' : 'disabled'),
            ],
          ),
          const SizedBox(height: 12),
          if (provider.baseUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Base URL: ${provider.baseUrl}'),
            ),
          Text(
            'Models',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          if (provider.models.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('No models configured.'),
            ),
          for (final model in provider.models)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.surface.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${model.displayName} (${model.id})'),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            AiSettingsChip(label: _enumName(model.modelKind)),
                            AiSettingsChip(label: 'ctx=${model.contextWindow}'),
                            AiSettingsChip(
                              label: model.supportsImages ? 'images:on' : 'images:off',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    children: [
                      Switch(
                        value: model.enabled,
                        onChanged: (value) => onEditModel(model.copyWith(enabled: value)),
                      ),
                      IconButton(
                        onPressed: () => onEditModel(model),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        onPressed: () => onDeleteModel(model.id),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onAddModel,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Model'),
            ),
          ),
        ],
      ),
    );
  }
}

Future<AiProviderConfig?> _showProviderDialog(
  BuildContext context, {
  required AiSettingsViewModel vm,
  required AiProviderConfig? existing,
}) async {
  final idController = TextEditingController(text: existing?.id ?? vm.createStableId('provider'));
  final nameController = TextEditingController(text: existing?.name ?? 'New Provider');
  final baseUrlController = TextEditingController(text: existing?.baseUrl ?? '');
  final apiKeyEnvController = TextEditingController(text: existing?.apiKeyEnv ?? '');
  final apiKeyController = TextEditingController(text: existing?.apiKey ?? '');
  final headersController = TextEditingController(text: existing?.headersJson ?? '{}');
  var kind = existing?.kind ?? ProviderKind.openAiResponses;
  var enabled = existing?.enabled ?? true;

  final submitted = await showAiSettingsDialog<bool>(
    context: context,
    title: existing == null ? 'Add Provider' : 'Edit Provider',
    subtitle: 'Define how Sirix connects to this provider and which authentication fields it should use.',
    width: 620,
    child: StatefulBuilder(
      builder: (context, setState) {
        return AiSettingsFieldGroup(
          children: [
            TextField(controller: idController, decoration: const InputDecoration(labelText: 'Provider ID')),
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Display Name')),
            DropdownButtonFormField<ProviderKind>(
              value: kind,
              decoration: const InputDecoration(labelText: 'Provider Kind'),
              items: ProviderKind.values
                  .map((value) => DropdownMenuItem(
                        value: value,
                        child: Text(_enumName(value)),
                      ))
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() => kind = value);
                }
              },
            ),
            TextField(controller: baseUrlController, decoration: const InputDecoration(labelText: 'Base URL')),
            TextField(controller: apiKeyEnvController, decoration: const InputDecoration(labelText: 'API Key Env Var')),
            TextField(controller: apiKeyController, decoration: const InputDecoration(labelText: 'API Key (optional inline)')),
            TextField(controller: headersController, decoration: const InputDecoration(labelText: 'Headers JSON')),
            AiSettingsToggleTile(
              title: 'Enabled',
              subtitle: 'Allow this provider to be selected by agents.',
              value: enabled,
              onChanged: (value) => setState(() => enabled = value),
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

  final previousModels = existing?.models ?? const <AiModelConfig>[];
  return AiProviderConfig(
    id: idController.text.trim(),
    name: nameController.text.trim(),
    kind: kind,
    baseUrl: baseUrlController.text.trim(),
    apiKeyEnv: apiKeyEnvController.text.trim(),
    apiKey: apiKeyController.text.trim(),
    headersJson: headersController.text.trim().isEmpty ? '{}' : headersController.text.trim(),
    enabled: enabled,
    models: previousModels,
  );
}

Future<AiModelConfig?> _showModelDialog(
  BuildContext context, {
  required AiSettingsViewModel vm,
  required AiProviderConfig provider,
  required AiModelConfig? existing,
}) async {
  final idController = TextEditingController(text: existing?.id ?? vm.createStableId('model'));
  final nameController = TextEditingController(text: existing?.displayName ?? 'New Model');
  final contextController = TextEditingController(
    text: (existing?.contextWindow ?? 128000).toString(),
  );
  var kind = existing?.modelKind ?? ModelKind.text;
  var supportsImages = existing?.supportsImages ?? false;
  var enabled = existing?.enabled ?? true;

  final submitted = await showAiSettingsDialog<bool>(
    context: context,
    title: existing == null ? 'Add Model (${provider.name})' : 'Edit Model (${provider.name})',
    subtitle: 'Tune the model capabilities Sirix should assume for this provider entry.',
    width: 560,
    child: StatefulBuilder(
      builder: (context, setState) {
        return AiSettingsFieldGroup(
          children: [
            TextField(controller: idController, decoration: const InputDecoration(labelText: 'Model ID')),
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Display Name')),
            DropdownButtonFormField<ModelKind>(
              value: kind,
              decoration: const InputDecoration(labelText: 'Model Kind'),
              items: ModelKind.values
                  .map((value) => DropdownMenuItem(
                        value: value,
                        child: Text(_enumName(value)),
                      ))
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() => kind = value);
                }
              },
            ),
            TextField(
              controller: contextController,
              decoration: const InputDecoration(labelText: 'Context Window'),
              keyboardType: TextInputType.number,
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                AiSettingsToggleTile(
                  title: 'Supports Images',
                  value: supportsImages,
                  onChanged: (value) => setState(() => supportsImages = value),
                ),
                AiSettingsToggleTile(
                  title: 'Enabled',
                  value: enabled,
                  onChanged: (value) => setState(() => enabled = value),
                ),
              ],
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

  return AiModelConfig(
    id: idController.text.trim(),
    displayName: nameController.text.trim(),
    modelKind: kind,
    contextWindow: int.tryParse(contextController.text.trim()) ?? 128000,
    supportsImages: supportsImages,
    enabled: enabled,
  );
}

String _enumName(Object value) => value.toString().split('.').last;
