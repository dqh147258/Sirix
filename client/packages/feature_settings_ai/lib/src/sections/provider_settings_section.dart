import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
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
    final defaultAgent = state.config.agents.where((item) => item.id == 'codex').isEmpty
        ? null
        : state.config.agents.firstWhere((item) => item.id == 'codex');

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
            authStatus: state.openAiAuthStatuses[provider.id],
            authBusy: state.authBusyProviderIds.contains(provider.id),
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
            onRefreshAuthStatus: provider.kind == ProviderKind.openAiCodexOauth
                ? () => unawaited(vm.refreshOpenAiAuthStatus(provider.id))
                : null,
            onStartOpenAiLogin: provider.kind == ProviderKind.openAiCodexOauth
                ? () async {
                    try {
                      final authUrl = await vm.startOpenAiAuthLogin(provider.id);
                      await _openExternalUrl(authUrl);
                    } catch (error, stackTrace) {
                      AppLogger.warn(
                        '[OPENAI_AUTH] failed to open browser provider_id=${provider.id} error=$error',
                      );
                      AppLogger.warn(
                        '[OPENAI_AUTH] browser launch stack provider_id=${provider.id} stack=$stackTrace',
                      );
                    }
                  }
                : null,
            onImportOpenAiAuthJson: provider.kind == ProviderKind.openAiCodexOauth
                ? () async {
                    try {
                      final authJson = await _showOpenAiAuthImportDialog(context);
                      if (authJson == null) {
                        return;
                      }
                      await vm.importOpenAiAuthJson(
                        providerId: provider.id,
                        authJson: authJson,
                      );
                    } catch (error, stackTrace) {
                      AppLogger.warn(
                        '[OPENAI_AUTH] failed to import auth json provider_id=${provider.id} error=$error',
                      );
                      AppLogger.warn(
                        '[OPENAI_AUTH] import json stack provider_id=${provider.id} stack=$stackTrace',
                      );
                    }
                  }
                : null,
            onLogoutOpenAiAuth: provider.kind == ProviderKind.openAiCodexOauth
                ? () async {
                    try {
                      await vm.logoutOpenAiAuth(provider.id);
                    } catch (error, stackTrace) {
                      AppLogger.warn(
                        '[OPENAI_AUTH] failed to logout provider_id=${provider.id} error=$error',
                      );
                      AppLogger.warn(
                        '[OPENAI_AUTH] logout stack provider_id=${provider.id} stack=$stackTrace',
                      );
                    }
                  }
                : null,
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
    required this.authStatus,
    required this.authBusy,
    required this.defaultProviderId,
    required this.defaultModelId,
    required this.discoveringModels,
    required this.onToggleEnabled,
    required this.onSetDefaultProviderContext,
    required this.onEdit,
    required this.onDelete,
    required this.onDiscoverModels,
    required this.onRefreshAuthStatus,
    required this.onStartOpenAiLogin,
    required this.onImportOpenAiAuthJson,
    required this.onLogoutOpenAiAuth,
    required this.onAddModel,
    required this.onEditModel,
    required this.onSetDefaultModel,
    required this.onDeleteModel,
  });

  final AiProviderConfig provider;
  final OpenAiAuthStatus? authStatus;
  final bool authBusy;
  final String? defaultProviderId;
  final String? defaultModelId;
  final bool discoveringModels;
  final ValueChanged<bool> onToggleEnabled;
  final ValueChanged<int?> onSetDefaultProviderContext;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDiscoverModels;
  final VoidCallback? onRefreshAuthStatus;
  final Future<void> Function()? onStartOpenAiLogin;
  final Future<void> Function()? onImportOpenAiAuthJson;
  final Future<void> Function()? onLogoutOpenAiAuth;
  final VoidCallback onAddModel;
  final ValueChanged<AiModelConfig> onEditModel;
  final ValueChanged<String> onSetDefaultModel;
  final ValueChanged<String> onDeleteModel;

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  bool _expanded = true;

  @override
  void initState() {
    super.initState();
    _expanded = _shouldExpandByDefault(widget.provider);
  }

  @override
  void didUpdateWidget(covariant _ProviderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider.id != widget.provider.id) {
      _expanded = _shouldExpandByDefault(widget.provider);
    }
  }

  bool _isDefaultModel(AiProviderConfig provider, AiModelConfig model) {
    return provider.id == widget.defaultProviderId && model.id == widget.defaultModelId;
  }

  bool get _supportsOpenAiAuth => widget.provider.kind == ProviderKind.openAiCodexOauth;

  // Provider 模型数量较少时直接展开，能减少一次点击；
  // 当模型数量较多时默认收起，避免设置页初始进入时被长列表撑满。
  bool _shouldExpandByDefault(AiProviderConfig provider) {
    return provider.models.length <= 6;
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
                  if (_supportsOpenAiAuth) ...[
                    _OpenAiAuthPanel(
                      status: widget.authStatus,
                      busy: widget.authBusy,
                      onRefresh: widget.onRefreshAuthStatus,
                      onStartLogin: widget.onStartOpenAiLogin,
                      onImportJson: widget.onImportOpenAiAuthJson,
                      onLogout: widget.onLogoutOpenAiAuth,
                    ),
                    const SizedBox(height: 16),
                  ],
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

class _OpenAiAuthPanel extends StatelessWidget {
  const _OpenAiAuthPanel({
    required this.status,
    required this.busy,
    required this.onRefresh,
    required this.onStartLogin,
    required this.onImportJson,
    required this.onLogout,
  });

  final OpenAiAuthStatus? status;
  final bool busy;
  final VoidCallback? onRefresh;
  final Future<void> Function()? onStartLogin;
  final Future<void> Function()? onImportJson;
  final Future<void> Function()? onLogout;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final authenticated = status?.authenticated ?? false;
    final statusText = authenticated
        ? 'Authenticated'
        : (status?.loginInProgress ?? false)
            ? 'Waiting For Browser'
            : 'Not Authenticated';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user_outlined, color: palette.secondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'OpenAI Codex OAuth',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontFamily: 'Space Grotesk',
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: palette.primaryBright,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _MetricBlock(
                label: 'Auth Status',
                value: statusText,
                valueColor: authenticated ? palette.primaryBright : palette.textMuted,
                alignStart: true,
              ),
              _MetricBlock(
                label: 'Account',
                value: status?.email ?? status?.accountId ?? 'Unavailable',
                valueColor: palette.textPrimary,
                alignStart: true,
              ),
              _MetricBlock(
                label: 'Plan',
                value: status?.planType ?? 'Unknown',
                valueColor: palette.secondary,
                alignStart: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.sync_rounded),
                label: const Text('Refresh Status'),
              ),
              FilledButton.icon(
                onPressed: busy || onStartLogin == null
                    ? null
                    : () async {
                        await onStartLogin!.call();
                      },
                icon: const Icon(Icons.open_in_browser_rounded),
                label: const Text('Browser Login'),
              ),
              OutlinedButton.icon(
                onPressed: busy || onImportJson == null
                    ? null
                    : () async {
                        await onImportJson!.call();
                      },
                icon: const Icon(Icons.upload_file_rounded),
                label: const Text('Import JSON'),
              ),
              if (authenticated)
                TextButton.icon(
                  onPressed: busy || onLogout == null
                      ? null
                      : () async {
                          await onLogout!.call();
                        },
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Sign Out'),
                ),
            ],
          ),
        ],
      ),
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
        final isOpenAiOauth = kind == ProviderKind.openAiCodexOauth;
        final isOpenAiCodexApi = kind == ProviderKind.openAiCodexApi;
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
              decoration: InputDecoration(
                labelText: 'Base URL',
                helperText: isOpenAiOauth
                    ? 'Codex OAuth 默认使用 ChatGPT Codex backend。通常不需要改动。'
                    : null,
              ),
              readOnly: isOpenAiOauth,
            ),
            TextField(
              controller: defaultContextWindowController,
              decoration: const InputDecoration(
                labelText: 'Provider Default Context Window',
                hintText: 'Leave blank to use Sirix vendor defaults',
              ),
              keyboardType: TextInputType.number,
            ),
            if (!isOpenAiOauth) ...[
              TextField(
                controller: apiKeyEnvController,
                decoration: const InputDecoration(labelText: 'API Key Env Var'),
              ),
              TextField(
                controller: apiKeyController,
                decoration: InputDecoration(
                  labelText: isOpenAiCodexApi
                      ? 'API Key (optional inline)'
                      : 'API Key (optional inline)',
                ),
              ),
            ],
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
    supportedReasoningEfforts: existing?.supportedReasoningEfforts,
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

// OpenAI auth JSON 导入不能再直接绑定系统文件选择器：
// 这次用户反馈的实际问题就是按钮点击后没有任何可见反馈，而原实现失败时只会写日志。
// 因此这里先弹一个可见对话框，让用户始终能看到导入入口；文件选择器只是辅助能力，
// 即使文件选择器插件失效，用户仍然可以通过拖拽文件、手动路径或直接粘贴完整的
// auth.json 内容完成导入，避免把功能绑死在单一平台实现上。
Future<Map<String, dynamic>?> _showOpenAiAuthImportDialog(BuildContext context) async {
  final controller = TextEditingController();
  final pathController = TextEditingController(text: _defaultCodexAuthJsonPath());
  final validationError = ValueNotifier<String?>(null);
  final loadingFromFile = ValueNotifier<bool>(false);
  final dragActive = ValueNotifier<bool>(false);
  final jsonEncoder = const JsonEncoder.withIndent('  ');

  try {
    return await showAiSettingsDialog<Map<String, dynamic>>(
      context: context,
      title: 'Import OpenAI Auth JSON',
      subtitle:
          'Load a Codex auth.json file or paste the JSON payload directly. The picker will try to open from the path below, so hidden folders such as ~/.codex can still be reached without relying on the file dialog to reveal them first.',
      width: 760,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: loadingFromFile,
                builder: (context, busy, child) {
                  return OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            loadingFromFile.value = true;
                            try {
                              final authJson = await _pickOpenAiAuthJsonWithFallback(
                                fallbackPath: pathController.text,
                              );
                              if (authJson == null) {
                                return;
                              }
                              controller.text = jsonEncoder.convert(authJson);
                              validationError.value = null;
                            } catch (error) {
                              validationError.value = 'Failed to load JSON file: $error';
                            } finally {
                              loadingFromFile.value = false;
                            }
                          },
                    icon: busy
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: context.sirix.primaryBright,
                            ),
                          )
                        : const Icon(Icons.folder_open_rounded),
                    label: Text(busy ? 'Loading...' : 'Load From File'),
                  );
                },
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Expected shape: auth_mode + tokens.access_token + tokens.refresh_token + tokens.account_id.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.sirix.textMuted,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: dragActive,
            builder: (context, isDragging, child) {
              final palette = context.sirix;
              return DropTarget(
                onDragEntered: (details) {
                  dragActive.value = true;
                },
                onDragExited: (details) {
                  dragActive.value = false;
                },
                onDragDone: (details) async {
                  dragActive.value = false;
                  try {
                    final authJson = await _readOpenAiAuthJsonFromDropItems(details.files);
                    controller.text = jsonEncoder.convert(authJson);
                    validationError.value = null;
                  } catch (error) {
                    validationError.value = 'Failed to import dropped file: $error';
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: isDragging
                        ? palette.primaryBright.withValues(alpha: 0.12)
                        : palette.surfaceMuted.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDragging ? palette.primaryBright : palette.glassStroke,
                      width: isDragging ? 1.4 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.file_download_outlined,
                            color: isDragging ? palette.primaryBright : palette.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            isDragging ? 'Release To Import auth.json' : 'Drag auth.json Here',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontFamily: 'Space Grotesk',
                                  fontWeight: FontWeight.w700,
                                  color: isDragging ? palette.primaryBright : palette.textPrimary,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Supports desktop drag-and-drop so import does not depend only on the file picker.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                            ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: pathController,
                  decoration: const InputDecoration(
                    labelText: 'Local JSON File Path',
                    hintText: '~/.codex/auth.json',
                    helperText:
                        'Load From File will use this path to choose the initial folder, including hidden folders.',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    final authJson = await _readOpenAiAuthJsonFromPath(pathController.text);
                    controller.text = jsonEncoder.convert(authJson);
                    validationError.value = null;
                  } catch (error) {
                    validationError.value = 'Failed to read path: $error';
                  }
                },
                icon: const Icon(Icons.description_outlined),
                label: const Text('Load Path'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            minLines: 14,
            maxLines: 22,
            decoration: const InputDecoration(
              labelText: 'Auth JSON',
              hintText: '{\n  "auth_mode": "chatgpt",\n  "tokens": {\n    ...\n  }\n}',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<String?>(
            valueListenable: validationError,
            builder: (context, errorText, child) {
              if (errorText == null || errorText.trim().isEmpty) {
                return const SizedBox.shrink();
              }
              return Text(
                errorText,
                style: TextStyle(
                  color: context.sirix.error,
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                ),
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            try {
              final decoded = _decodeOpenAiAuthJsonText(controller.text);
              validationError.value = null;
              Navigator.of(context).pop(decoded);
            } catch (error) {
              validationError.value = '$error';
            }
          },
          child: const Text('Import'),
        ),
      ],
    );
  } finally {
    controller.dispose();
    pathController.dispose();
    validationError.dispose();
    loadingFromFile.dispose();
    dragActive.dispose();
  }
}

Future<Map<String, dynamic>?> _pickOpenAiAuthJsonWithFallback({
  required String fallbackPath,
}) async {
  try {
    final picked = await _pickOpenAiAuthJson(
      fallbackPath: fallbackPath,
    );
    if (picked != null) {
      return picked;
    }
  } catch (_) {
    // 先吞掉，让后续 fallback 继续尝试；最终错误会由 fallback 抛出。
    AppLogger.warn('[OPENAI_AUTH] file picker failed, switching to drag/path/paste fallback');
  }

  final normalizedFallbackPath = _normalizeLocalPath(fallbackPath);
  throw FileSystemException(
    '无法打开系统文件选择器。请使用拖拽、“Load Path” 读取本地路径，或直接粘贴 auth JSON。',
    normalizedFallbackPath.isEmpty ? null : normalizedFallbackPath,
  );
}

Future<Map<String, dynamic>?> _pickOpenAiAuthJson({
  required String fallbackPath,
}) async {
  AppLogger.info('[OPENAI_AUTH] opening file picker for auth json');
  final initialDirectory = _deriveInitialDirectoryForPicker(fallbackPath);
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Choose OpenAI auth JSON',
    initialDirectory: initialDirectory,
    // 不再依赖原生文件对话框的扩展名过滤。
    // 当前用户场景里 picker 已经能进入 ~/.codex，但 auth.json 仍然处于不可选状态，
    // 更稳妥的做法是允许选择任意文件，再由 Sirix 自己读取并校验 JSON 结构。
    type: FileType.any,
    allowMultiple: false,
    withData: false,
  );
  AppLogger.info(
    '[OPENAI_AUTH] file picker completed has_result=${result != null} initial_directory=$initialDirectory',
  );
  if (result == null) {
    return null;
  }

  if (result.files.isEmpty) {
    return null;
  }
  final pickedFile = result.files.first;

  final path = pickedFile.path;
  if (path == null || path.trim().isEmpty) {
    throw const FileSystemException('文件选择器没有返回有效路径');
  }

  return _readOpenAiAuthJsonFromPath(path);
}

Future<Map<String, dynamic>> _readOpenAiAuthJsonFromPath(String path) async {
  final normalizedPath = _normalizeLocalPath(path);
  if (normalizedPath.isEmpty) {
    throw const FormatException('文件路径不能为空');
  }

  final file = File(normalizedPath);
  if (!await file.exists()) {
    throw FileSystemException('文件不存在', normalizedPath);
  }

  final raw = await file.readAsString();
  return _decodeOpenAiAuthJsonText(raw);
}

Future<Map<String, dynamic>> _readOpenAiAuthJsonFromDropItems(List<DropItem> items) async {
  if (items.isEmpty) {
    throw const FormatException('未收到拖拽文件');
  }

  DropItemFile? firstFile;
  for (final item in items) {
    if (item is! DropItemFile) {
      continue;
    }
    firstFile ??= item;
    final candidateName = item.name.toLowerCase();
    if (!candidateName.endsWith('.json') && candidateName != 'auth.json') {
      continue;
    }
    final raw = await item.readAsString();
    return _decodeOpenAiAuthJsonText(raw);
  }

  if (firstFile == null) {
    throw const FormatException('拖拽内容里没有可读取的文件');
  }

  final raw = await firstFile.readAsString();
  return _decodeOpenAiAuthJsonText(raw);
}

String _normalizeLocalPath(String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed == '~' || trimmed.startsWith('~/')) {
    final home = Platform.environment['HOME'];
    if (home == null || home.trim().isEmpty) {
      return trimmed;
    }
    if (trimmed == '~') {
      return home;
    }
    return '$home/${trimmed.substring(2)}';
  }
  return trimmed;
}

String? _deriveInitialDirectoryForPicker(String rawPath) {
  final normalized = _normalizeLocalPath(rawPath);
  if (normalized.isEmpty) {
    return null;
  }

  final file = File(normalized);
  final parent = file.parent.path.trim();
  if (parent.isEmpty || parent == '.') {
    return null;
  }
  return parent;
}

String _defaultCodexAuthJsonPath() {
  final home = Platform.environment['HOME'];
  if (home == null || home.trim().isEmpty) {
    return '~/.codex/auth.json';
  }
  return '$home/.codex/auth.json';
}

Map<String, dynamic> _decodeOpenAiAuthJsonText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Auth JSON 不能为空');
  }

  final decoded = jsonDecode(trimmed);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Auth JSON 必须是对象结构');
  }
  return decoded;
}

Future<void> _openExternalUrl(Uri uri) async {
  final url = uri.toString();
  late final String executable;
  late final List<String> arguments;

  if (Platform.isMacOS) {
    executable = 'open';
    arguments = [url];
  } else if (Platform.isWindows) {
    executable = 'cmd';
    arguments = ['/c', 'start', '', url];
  } else {
    executable = 'xdg-open';
    arguments = [url];
  }

  final process = await Process.start(executable, arguments);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    final stderr = await utf8.decoder.bind(process.stderr).join();
    throw StateError('无法打开浏览器: $url, exitCode=$exitCode, stderr=$stderr');
  }
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
    id: 'openai-codex-oauth',
    name: 'OpenAI Codex OAuth',
    kind: ProviderKind.openAiCodexOauth,
    baseUrl: 'https://chatgpt.com/backend-api/codex',
    apiKeyEnv: '',
    description: 'ChatGPT/Codex OAuth provider. Supports browser login or imported auth JSON.',
    defaultContextWindow: 400000,
  ),
  _ProviderTemplate(
    id: 'openai-codex-api',
    name: 'OpenAI Codex API',
    kind: ProviderKind.openAiCodexApi,
    baseUrl: 'https://api.openai.com/v1',
    apiKeyEnv: 'OPENAI_API_KEY',
    description: 'OpenAI Codex API provider with configurable Base URL and API key.',
    defaultContextWindow: 400000,
  ),
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
    ProviderKind.openAiCodexOauth => 'OpenAI Codex OAuth',
    ProviderKind.openAiCodexApi => 'OpenAI Codex API',
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
