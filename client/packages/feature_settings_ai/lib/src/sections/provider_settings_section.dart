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

class _ProviderCard extends StatefulWidget {
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
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  bool _expanded = true;

  bool _isDefaultModel(AiProviderConfig provider, AiModelConfig model) {
    return provider.id == widget.defaultProviderId && model.id == widget.defaultModelId;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final defaultModelConfig = widget.provider.models
        .where((m) => _isDefaultModel(widget.provider, m))
        .firstOrNull;

    return Container(
      clipBehavior: Clip.antiAlias,
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
          // Header / Summary Area
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Keep the new dense summary styling, but split it into two rows
                    // before the header runs out of horizontal space on 1100px layouts.
                    final useStackedSummary = constraints.maxWidth < 980;
                    final summaryChildren = [
                      _MetricBlock(
                        label: 'Context Window',
                        value: _providerContextLabel(widget.provider),
                        valueColor: palette.secondary,
                        alignStart: useStackedSummary,
                      ),
                      _MetricBlock(
                        label: 'CLI Default Model',
                        value: defaultModelConfig?.displayName ?? 'Not Set',
                        valueColor: palette.textPrimary,
                        alignStart: useStackedSummary,
                      ),
                      _ProviderStatusBlock(
                        enabled: widget.provider.enabled,
                        alignStart: useStackedSummary,
                        onChanged: widget.onToggleEnabled,
                      ),
                      _ProviderActionMenu(
                        provider: widget.provider,
                        onEdit: widget.onEdit,
                        onDelete: widget.onDelete,
                        onSetDefaultProviderContext: widget.onSetDefaultProviderContext,
                      ),
                    ];

                    final leading = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          color: palette.textMuted,
                        ),
                        const SizedBox(width: 16),
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: palette.surfaceMuted,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.hub_outlined, color: palette.secondary, size: 20),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.provider.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontFamily: 'Space Grotesk',
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'ID: ${widget.provider.id}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontFamily: 'JetBrains Mono',
                                      fontSize: 10,
                                      color: palette.textMuted,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );

                    if (useStackedSummary) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          leading,
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 24,
                            runSpacing: 16,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: summaryChildren,
                          ),
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: leading),
                        const SizedBox(width: 24),
                        Flexible(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Wrap(
                              spacing: 24,
                              runSpacing: 16,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              alignment: WrapAlignment.end,
                              children: summaryChildren,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          // Expanded Content Area (Models Table)
          if (_expanded)
            Container(
              color: palette.background.withValues(alpha: 0.3),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Models',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              fontFamily: 'Space Grotesk',
                              letterSpacing: 1.2,
                              color: palette.textSecondary,
                            ),
                      ),
                      Row(
                        children: [
                          if (widget.discoveringModels)
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: palette.primaryBright,
                              ),
                            )
                          else
                            TextButton.icon(
                              onPressed: widget.onDiscoverModels,
                              icon: const Icon(Icons.sync_rounded, size: 16),
                              label: const Text('Fetch Models'),
                              style: TextButton.styleFrom(
                                foregroundColor: palette.textSecondary,
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                minimumSize: Size.zero,
                              ),
                            ),
                          const SizedBox(width: 12),
                          TextButton.icon(
                            onPressed: widget.onAddModel,
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('Add Model'),
                            style: TextButton.styleFrom(
                              foregroundColor: palette.primaryBright,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (widget.provider.models.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Text(
                          'No models configured.',
                          style: TextStyle(color: palette.textMuted),
                        ),
                      ),
                    )
                  else
                    // Models list mapping the exact aesthetic of table row from reference
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: widget.provider.models.length,
                      itemBuilder: (context, index) {
                        final model = widget.provider.models[index];
                        final isDefault = _isDefaultModel(widget.provider, model);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: palette.surfaceMuted.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(6),
                            border: isDefault
                                ? Border(
                                    left: BorderSide(color: palette.primaryBright, width: 3),
                                  )
                                : null,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            model.displayName,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: palette.textPrimary,
                                            ),
                                          ),
                                          if (isDefault) ...[
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: palette.primaryBright.withValues(alpha: 0.2),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                'CLI DEFAULT',
                                                style: TextStyle(
                                                  fontSize: 8,
                                                  fontWeight: FontWeight.w800,
                                                  color: palette.primaryBright,
                                                  letterSpacing: 0.5,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    model.id,
                                    style: TextStyle(
                                      fontFamily: 'JetBrains Mono',
                                      fontSize: 11,
                                      color: palette.textMuted,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 1,
                                  child: Text(
                                    _effectiveContextWindowLabel(widget.provider, model),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontFamily: 'JetBrains Mono',
                                      fontSize: 12,
                                      color: palette.secondary,
                                    ),
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Switch(
                                      value: model.enabled,
                                      onChanged: (value) => widget.onEditModel(model.copyWith(enabled: value)),
                                      activeThumbColor: palette.primaryBright,
                                    ),
                                    PopupMenuButton<_ProviderModelAction>(
                                      icon: Icon(Icons.more_vert_rounded, color: palette.textMuted, size: 20),
                                      color: palette.surfaceRaised,
                                      onSelected: (action) {
                                        // Route model actions through onSelected so dialog/menu
                                        // timing stays stable after the popup is dismissed.
                                        switch (action) {
                                          case _ProviderModelAction.edit:
                                            widget.onEditModel(model);
                                            break;
                                          case _ProviderModelAction.setCliDefault:
                                            widget.onSetDefaultModel(model.id);
                                            break;
                                          case _ProviderModelAction.delete:
                                            widget.onDeleteModel(model.id);
                                            break;
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        const PopupMenuItem(
                                          value: _ProviderModelAction.edit,
                                          child: Text('Edit Model'),
                                        ),
                                        if (model.enabled && model.modelKind == ModelKind.text)
                                          const PopupMenuItem(
                                            value: _ProviderModelAction.setCliDefault,
                                            child: Text('Set as CLI Default'),
                                          ),
                                        PopupMenuItem(
                                          value: _ProviderModelAction.delete,
                                          child: Text('Delete Model', style: TextStyle(color: palette.error)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({
    required this.label,
    required this.value,
    required this.valueColor,
    this.alignStart = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool alignStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignStart ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 10,
                fontFamily: 'JetBrains Mono',
                color: context.sirix.textMuted,
                letterSpacing: 1.2,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'JetBrains Mono',
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

enum _ProviderActionMenuItem {
  edit,
  editContextWindow,
  delete,
}

enum _ProviderModelAction {
  edit,
  setCliDefault,
  delete,
}

class _ProviderStatusBlock extends StatelessWidget {
  const _ProviderStatusBlock({
    required this.enabled,
    required this.alignStart,
    required this.onChanged,
  });

  final bool enabled;
  final bool alignStart;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Column(
      crossAxisAlignment: alignStart ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: [
        Text(
          'Status',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 10,
                fontFamily: 'JetBrains Mono',
                color: palette.textMuted,
                letterSpacing: 1.2,
              ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              enabled ? 'ENABLED' : 'DISABLED',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: enabled ? palette.primaryBright : palette.textMuted,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 24,
              child: Switch(
                value: enabled,
                onChanged: onChanged,
                activeThumbColor: palette.primaryBright,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProviderActionMenu extends StatelessWidget {
  const _ProviderActionMenu({
    required this.provider,
    required this.onEdit,
    required this.onDelete,
    required this.onSetDefaultProviderContext,
  });

  final AiProviderConfig provider;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<int?> onSetDefaultProviderContext;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return PopupMenuButton<_ProviderActionMenuItem>(
      icon: Icon(Icons.more_vert_rounded, color: palette.textMuted),
      color: palette.surfaceRaised,
      onSelected: (action) async {
        // Using onSelected avoids racing the popup dismissal with a dialog open.
        switch (action) {
          case _ProviderActionMenuItem.edit:
            onEdit();
            break;
          case _ProviderActionMenuItem.editContextWindow:
            final updated = await _showProviderContextWindowDialog(
              context,
              provider: provider,
            );
            if (!context.mounted || updated == null) {
              return;
            }
            onSetDefaultProviderContext(updated);
            break;
          case _ProviderActionMenuItem.delete:
            onDelete();
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _ProviderActionMenuItem.edit,
          child: Text('Edit Provider'),
        ),
        const PopupMenuItem(
          value: _ProviderActionMenuItem.editContextWindow,
          child: Text('Edit Context Window'),
        ),
        PopupMenuItem(
          value: _ProviderActionMenuItem.delete,
          child: Text('Delete Provider', style: TextStyle(color: palette.error)),
        ),
      ],
    );
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
