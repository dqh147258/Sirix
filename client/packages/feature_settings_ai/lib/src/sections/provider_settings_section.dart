import 'dart:async';

import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import '../ai_settings_state.dart';
import '../ai_settings_view_model.dart';
import '../settings_ui.dart';

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
    final defaultAgent = state.config.agents.where((item) => item.id == 'default-agent').isEmpty
        ? null
        : state.config.agents.firstWhere((item) => item.id == 'default-agent');

    return ListView(
      children: [
        AiSettingsSectionHeader(
          title: 'Providers',
          subtitle:
              'Register model backends, use presets for common vendors, and fetch supported models directly from each provider endpoint.',
          action: FilledButton.icon(
            onPressed: () async {
              final created = await _showProviderDialog(
                context,
                vm: vm,
                existing: null,
              );
              if (created != null) {
                vm.upsertProvider(created.provider);
                if (created.fetchModelsAfterSave) {
                  unawaited(vm.discoverProviderModels(created.provider));
                }
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
            defaultProviderId: defaultAgent?.providerId,
            defaultModelId: defaultAgent?.modelId,
            discoveringModels: state.discoveringProviderIds.contains(provider.id),
            onToggleEnabled: (value) => vm.upsertProvider(provider.copyWith(enabled: value)),
            onSetDefaultProviderContext: (value) => vm.updateProviderDefaultContextWindow(
              providerId: provider.id,
              contextWindow: value,
            ),
            onEdit: () async {
              final edited = await _showProviderDialog(
                context,
                vm: vm,
                existing: provider,
              );
              if (edited != null) {
                vm.upsertProvider(edited.provider);
                if (edited.fetchModelsAfterSave) {
                  unawaited(vm.discoverProviderModels(edited.provider));
                }
              }
            },
            onDelete: () => vm.removeProvider(provider.id),
            onDiscoverModels: () => unawaited(vm.discoverProviderModels(provider)),
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
            onSetDefaultModel: (modelId) => vm.setDefaultModel(
              providerId: provider.id,
              modelId: modelId,
            ),
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
    required this.defaultProviderId,
    required this.defaultModelId,
    required this.discoveringModels,
    required this.onToggleEnabled,
    required this.onSetDefaultProviderContext,
    required this.onEdit,
    required this.onDelete,
    required this.onDiscoverModels,
    required this.onAddModel,
    required this.onEditModel,
    required this.onSetDefaultModel,
    required this.onDeleteModel,
  });

  final AiProviderConfig provider;
  final String? defaultProviderId;
  final String? defaultModelId;
  final bool discoveringModels;
  final ValueChanged<bool> onToggleEnabled;
  final ValueChanged<int?> onSetDefaultProviderContext;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDiscoverModels;
  final VoidCallback onAddModel;
  final ValueChanged<AiModelConfig> onEditModel;
  final ValueChanged<String> onSetDefaultModel;
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
                      '${provider.id} · ${_providerKindLabel(provider.kind)}',
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
              AiSettingsChip(label: _providerKindLabel(provider.kind)),
              AiSettingsChip(label: provider.enabled ? 'Enabled' : 'Disabled'),
              AiSettingsChip(
                label: 'default ctx=${_providerContextLabel(provider)}',
              ),
              if (provider.id == defaultProviderId) const AiSettingsChip(label: 'CLI default'),
            ],
          ),
          const SizedBox(height: 12),
          if (provider.baseUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Base URL: ${provider.baseUrl}'),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Provider default context window: ${_providerContextLabel(provider)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final updated = await _showProviderContextWindowDialog(
                      context,
                      provider: provider,
                    );
                    if (updated != null) {
                      onSetDefaultProviderContext(updated);
                    }
                  },
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Edit Default Context'),
                ),
              ],
            ),
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
                            AiSettingsChip(label: _modelKindLabel(model.modelKind)),
                            AiSettingsChip(
                              label: 'ctx=${_effectiveContextWindowLabel(provider, model)}',
                            ),
                            AiSettingsChip(
                              label: model.supportsImages ? 'images:on' : 'images:off',
                            ),
                            if (_isDefaultModel(provider, model))
                              const AiSettingsChip(label: 'CLI default'),
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
                        onPressed: model.enabled && model.modelKind == ModelKind.text
                            ? () => onSetDefaultModel(model.id)
                            : null,
                        icon: Icon(
                          _isDefaultModel(provider, model)
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                        ),
                        tooltip: _isDefaultModel(provider, model)
                            ? 'Current CLI default model'
                            : 'Set as CLI default model',
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
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: discoveringModels ? null : onDiscoverModels,
                icon: discoveringModels
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded),
                label: Text(discoveringModels ? 'Fetching…' : 'Fetch Models'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onAddModel,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add Model'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _isDefaultModel(AiProviderConfig provider, AiModelConfig model) {
    return provider.id == defaultProviderId && model.id == defaultModelId;
  }
}

Future<_ProviderDialogResult?> _showProviderDialog(
  BuildContext context, {
  required AiSettingsViewModel vm,
  required AiProviderConfig? existing,
}) async {
  final initialTemplate = _matchingProviderTemplate(existing);
  final idController = TextEditingController(
    text: existing?.id ?? initialTemplate?.id ?? vm.createStableId('provider'),
  );
  final nameController = TextEditingController(
    text: existing?.name ?? initialTemplate?.name ?? 'New Provider',
  );
  final baseUrlController = TextEditingController(
    text: existing?.baseUrl ?? initialTemplate?.baseUrl ?? '',
  );
  final apiKeyEnvController = TextEditingController(
    text: existing?.apiKeyEnv ?? initialTemplate?.apiKeyEnv ?? '',
  );
  final defaultContextWindowController = TextEditingController(
    text: (existing?.defaultContextWindow ?? initialTemplate?.defaultContextWindow)?.toString() ?? '',
  );
  final apiKeyController = TextEditingController(text: existing?.apiKey ?? '');
  final headersController = TextEditingController(
    text: existing?.headersJson ?? initialTemplate?.headersJson ?? '{}',
  );
  var templateId = initialTemplate?.id ?? _customProviderTemplateId;
  var kind = existing?.kind ?? initialTemplate?.kind ?? ProviderKind.openAiResponses;
  var enabled = existing?.enabled ?? true;
  var fetchModelsAfterSave = existing == null || (existing?.models.isEmpty ?? true);

  final submitted = await showAiSettingsDialog<bool>(
    context: context,
    title: existing == null ? 'Add Provider' : 'Edit Provider',
    subtitle:
        'Choose a preset for common vendors or configure the API manually. Sirix can fetch the model list from the provider after save.',
    width: 620,
    child: StatefulBuilder(
      builder: (context, setState) {
        return AiSettingsFieldGroup(
          children: [
            DropdownButtonFormField<String>(
              value: templateId,
              decoration: const InputDecoration(labelText: 'Preset'),
              items: [
                const DropdownMenuItem(
                  value: _customProviderTemplateId,
                  child: Text('Custom'),
                ),
                ..._providerTemplates.map(
                  (template) => DropdownMenuItem(
                    value: template.id,
                    child: Text(template.name),
                  ),
                ),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() {
                  templateId = value;
                  final template = _providerTemplateById(value);
                  if (template == null) {
                    return;
                  }
                  idController.text = template.id;
                  nameController.text = template.name;
                  baseUrlController.text = template.baseUrl;
                  apiKeyEnvController.text = template.apiKeyEnv;
                  defaultContextWindowController.text =
                      template.defaultContextWindow?.toString() ?? '';
                  headersController.text = template.headersJson;
                  kind = template.kind;
                  fetchModelsAfterSave = true;
                });
              },
            ),
            if (_providerTemplateById(templateId) case final template?)
              Text(
                template.description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.sirix.textMuted,
                    ),
              ),
            TextField(
              controller: idController,
              decoration: const InputDecoration(labelText: 'Provider ID'),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
            DropdownButtonFormField<ProviderKind>(
              value: kind,
              decoration: const InputDecoration(labelText: 'Provider Kind'),
              items: ProviderKind.values
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(_providerKindLabel(value)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() => kind = value);
                }
              },
            ),
            TextField(
              controller: baseUrlController,
              decoration: const InputDecoration(labelText: 'Base URL'),
            ),
            TextField(
              controller: defaultContextWindowController,
              decoration: const InputDecoration(
                labelText: 'Provider Default Context Window',
                hintText: 'Leave blank to use Sirix vendor defaults',
              ),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: apiKeyEnvController,
              decoration: const InputDecoration(labelText: 'API Key Env Var'),
            ),
            TextField(
              controller: apiKeyController,
              decoration: const InputDecoration(labelText: 'API Key (optional inline)'),
            ),
            TextField(
              controller: headersController,
              decoration: const InputDecoration(labelText: 'Headers JSON'),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                AiSettingsToggleTile(
                  title: 'Enabled',
                  subtitle: 'Allow this provider to be selected by agents.',
                  value: enabled,
                  onChanged: (value) => setState(() => enabled = value),
                ),
                AiSettingsToggleTile(
                  title: 'Fetch Models After Save',
                  width: 320,
                  subtitle: 'Query the provider Base URL and refresh this provider model list.',
                  value: fetchModelsAfterSave,
                  onChanged: (value) => setState(() => fetchModelsAfterSave = value),
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

  final previousModels = existing?.models ?? const <AiModelConfig>[];
  return _ProviderDialogResult(
    provider: AiProviderConfig(
      id: idController.text.trim(),
      name: nameController.text.trim(),
      kind: kind,
      defaultContextWindow: int.tryParse(defaultContextWindowController.text.trim()),
      baseUrl: baseUrlController.text.trim(),
      apiKeyEnv: apiKeyEnvController.text.trim(),
      apiKey: apiKeyController.text.trim(),
      headersJson: headersController.text.trim().isEmpty ? '{}' : headersController.text.trim(),
      enabled: enabled,
      models: previousModels,
    ),
    fetchModelsAfterSave: fetchModelsAfterSave,
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
    text: existing?.contextWindow?.toString() ?? '',
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
            TextField(
              controller: idController,
              decoration: const InputDecoration(labelText: 'Model ID'),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
            DropdownButtonFormField<ModelKind>(
              value: kind,
              decoration: const InputDecoration(labelText: 'Model Kind'),
              items: ModelKind.values
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(_modelKindLabel(value)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() => kind = value);
                }
              },
            ),
            TextField(
              controller: contextController,
              decoration: const InputDecoration(
                labelText: 'Context Window (optional)',
                hintText: 'Leave blank to use the provider default context window',
              ),
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
    contextWindow: int.tryParse(contextController.text.trim()),
    supportsImages: supportsImages,
    enabled: enabled,
  );
}

Future<int?> _showProviderContextWindowDialog(
  BuildContext context, {
  required AiProviderConfig provider,
}) async {
  final controller = TextEditingController(
    text: provider.defaultContextWindow?.toString() ?? '',
  );
  final submitted = await showAiSettingsDialog<bool>(
    context: context,
    title: 'Provider Default Context',
    subtitle:
        'Models without an explicit context window inherit this provider-level default. Leave blank to fall back to Sirix vendor heuristics.',
    width: 520,
    child: TextField(
      controller: controller,
      decoration: const InputDecoration(
        labelText: 'Default Context Window',
        hintText: 'Leave blank to use Sirix defaults',
      ),
      keyboardType: TextInputType.number,
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
    ],
  );

  if (submitted != true) {
    return null;
  }
  return int.tryParse(controller.text.trim());
}

class _ProviderDialogResult {
  const _ProviderDialogResult({
    required this.provider,
    required this.fetchModelsAfterSave,
  });

  final AiProviderConfig provider;
  final bool fetchModelsAfterSave;
}

String _providerContextLabel(AiProviderConfig provider) {
  final value = provider.defaultContextWindow;
  return value == null ? 'auto' : value.toString();
}

String _effectiveContextWindowLabel(AiProviderConfig provider, AiModelConfig model) {
  // 模型上下文长度允许留空；当留空时明确展示它会回退到 Provider 默认值，
  // 这样设置页里能直接看出最终生效来源，而不是只看到一个空字段。
  final modelContext = model.contextWindow;
  if (modelContext != null) {
    return modelContext.toString();
  }
  final providerDefault = provider.defaultContextWindow;
  if (providerDefault != null) {
    return '$providerDefault · provider';
  }
  return 'auto';
}

class _ProviderTemplate {
  const _ProviderTemplate({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.apiKeyEnv,
    required this.description,
    this.defaultContextWindow,
    this.headersJson = '{}',
  });

  final String id;
  final String name;
  final ProviderKind kind;
  final String baseUrl;
  final String apiKeyEnv;
  final String description;
  final int? defaultContextWindow;
  final String headersJson;
}

const String _customProviderTemplateId = '__custom__';

const List<_ProviderTemplate> _providerTemplates = [
  _ProviderTemplate(
    id: 'openai',
    name: 'OpenAI',
    kind: ProviderKind.openAiResponses,
    baseUrl: 'https://api.openai.com/v1',
    apiKeyEnv: 'OPENAI_API_KEY',
    description: 'OpenAI native Responses API endpoint.',
    defaultContextWindow: 200000,
  ),
  _ProviderTemplate(
    id: 'openrouter',
    name: 'OpenRouter',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://openrouter.ai/api/v1',
    apiKeyEnv: 'OPENROUTER_API_KEY',
    description: 'OpenAI-compatible router with a large multi-vendor model catalog.',
    defaultContextWindow: 128000,
  ),
  _ProviderTemplate(
    id: 'gemini',
    name: 'Google Gemini',
    kind: ProviderKind.gemini,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    apiKeyEnv: 'GEMINI_API_KEY',
    description: 'Gemini OpenAI compatibility endpoint.',
    defaultContextWindow: 1048576,
  ),
  _ProviderTemplate(
    id: 'anthropic',
    name: 'Anthropic',
    kind: ProviderKind.anthropic,
    baseUrl: 'https://api.anthropic.com/v1',
    apiKeyEnv: 'ANTHROPIC_API_KEY',
    description: 'Anthropic native API endpoint.',
    defaultContextWindow: 200000,
  ),
  _ProviderTemplate(
    id: 'groq',
    name: 'Groq',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.groq.com/openai/v1',
    apiKeyEnv: 'GROQ_API_KEY',
    description: 'Groq OpenAI-compatible endpoint for fast inference.',
    defaultContextWindow: 128000,
  ),
  _ProviderTemplate(
    id: 'xai',
    name: 'xAI',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.x.ai/v1',
    apiKeyEnv: 'XAI_API_KEY',
    description: 'xAI OpenAI-compatible endpoint.',
    defaultContextWindow: 128000,
  ),
  _ProviderTemplate(
    id: 'mistral',
    name: 'Mistral',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.mistral.ai/v1',
    apiKeyEnv: 'MISTRAL_API_KEY',
    description: 'Mistral model management and chat endpoint.',
    defaultContextWindow: 128000,
  ),
  _ProviderTemplate(
    id: 'moonshot',
    name: 'Moonshot',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.moonshot.ai/v1',
    apiKeyEnv: 'MOONSHOT_API_KEY',
    description: 'Moonshot OpenAI-compatible endpoint.',
    defaultContextWindow: 128000,
  ),
  _ProviderTemplate(
    id: 'together',
    name: 'Together AI',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.together.xyz/v1',
    apiKeyEnv: 'TOGETHER_API_KEY',
    description: 'Together AI OpenAI-compatible endpoint.',
    defaultContextWindow: 128000,
  ),
  _ProviderTemplate(
    id: 'sambanova',
    name: 'SambaNova',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.sambanova.ai/v1',
    apiKeyEnv: 'SAMBANOVA_API_KEY',
    description: 'SambaNova OpenAI-compatible endpoint.',
    defaultContextWindow: 128000,
  ),
  _ProviderTemplate(
    id: 'ollama',
    name: 'Ollama',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'http://localhost:11434/v1',
    apiKeyEnv: '',
    description: 'Local Ollama server exposing OpenAI-compatible routes.',
    defaultContextWindow: 128000,
  ),
  _ProviderTemplate(
    id: 'lmstudio',
    name: 'LM Studio',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'http://localhost:1234/v1',
    apiKeyEnv: '',
    description: 'Local LM Studio OpenAI-compatible endpoint.',
    defaultContextWindow: 128000,
  ),
];

_ProviderTemplate? _providerTemplateById(String id) {
  for (final template in _providerTemplates) {
    if (template.id == id) {
      return template;
    }
  }
  return null;
}

_ProviderTemplate? _matchingProviderTemplate(AiProviderConfig? provider) {
  if (provider == null) {
    return _providerTemplateById('openai');
  }
  for (final template in _providerTemplates) {
    if (template.kind == provider.kind &&
        template.baseUrl == provider.baseUrl &&
        template.apiKeyEnv == provider.apiKeyEnv) {
      return template;
    }
  }
  return null;
}

String _providerKindLabel(ProviderKind kind) {
  return switch (kind) {
    ProviderKind.openAiCompatible => 'OpenAI-compatible',
    ProviderKind.openAiResponses => 'OpenAI Responses',
    ProviderKind.gemini => 'Gemini',
    ProviderKind.anthropic => 'Anthropic',
  };
}

String _modelKindLabel(ModelKind kind) {
  return switch (kind) {
    ModelKind.text => 'Text',
    ModelKind.imageGeneration => 'Image generation',
    ModelKind.asr => 'Speech-to-text',
    ModelKind.tts => 'Text-to-speech',
    ModelKind.embedding => 'Embedding',
  };
}
