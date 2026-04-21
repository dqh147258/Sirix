import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'ai_settings_state.dart';

const String _defaultAgentId = 'codex';
const int _maxRecentWorkspaces = 50;

class _WorkspaceSettingsPayload {
  const _WorkspaceSettingsPayload({
    required this.workspaceRoot,
    required this.editableConfig,
    required this.editableShellRules,
    required this.effectiveConfig,
    required this.effectiveShellRules,
    required this.effectiveWorkspaceSource,
    required this.hasSirixConfig,
    required this.hasCodexConfig,
  });

  final String workspaceRoot;
  final SirixAiConfig editableConfig;
  final ShellRulesConfigModel editableShellRules;
  final SirixAiConfig effectiveConfig;
  final ShellRulesConfigModel effectiveShellRules;
  final String? effectiveWorkspaceSource;
  final bool hasSirixConfig;
  final bool hasCodexConfig;

  factory _WorkspaceSettingsPayload.fromResponse(
    WorkspaceSettingsResponseModel response,
  ) {
    return _WorkspaceSettingsPayload(
      workspaceRoot: response.workspaceRoot,
      editableConfig: _workspaceEditableToSirixConfig(response.editableConfig),
      editableShellRules: response.editableShellRules,
      effectiveConfig: response.effectiveConfig,
      effectiveShellRules: response.effectiveShellRules,
      effectiveWorkspaceSource: response.effectiveWorkspaceSource,
      hasSirixConfig: response.hasSirixConfig,
      hasCodexConfig: response.hasCodexConfig,
    );
  }
}

class AiSettingsViewModel extends BaseViewModel<AiSettingsState> {
  AiSettingsViewModel(this._localClient, this._scope)
      : super(
          AiSettingsState(
            scope: _scope,
            selectedSection: _defaultSectionForScope(_scope),
          ),
        );

  final DesktopLocalClient _localClient;
  final AiSettingsScope _scope;
  String? _loadedCacheKey;

  Future<void> load({bool force = false, String? workspaceRoot}) async {
    final requestedRoot = workspaceRoot?.trim();
    final cacheKey = '${_scope.name}:${requestedRoot ?? state.selectedWorkspaceRoot ?? ''}';
    if (_loadedCacheKey == cacheKey && !force) {
      return;
    }

    _loadedCacheKey = cacheKey;
    state = state.copyWith(loading: true, clearError: true, clearNotice: true);
    if (_scope == AiSettingsScope.workspace) {
      await _loadWorkspace(requestedRoot: requestedRoot);
      return;
    }

    await _loadGlobal();
  }

  Future<void> save() async {
    if (state.saving) {
      return;
    }

    state = state.copyWith(saving: true, clearError: true, clearNotice: true);
    if (_scope == AiSettingsScope.workspace) {
      await _saveWorkspace();
      return;
    }

    try {
      final compactedConfig = _compactAgentPermissionDeltas(
        state.config,
        globalReferenceConfig: state.globalReferenceConfig,
      );
      // Keep config.toml and shell-rules.json saves in one explicit transaction-like
      // flow so the desktop settings page reflects the exact pair of artifacts the
      // runtime will read on the next session launch.
      final saved = await _localClient.saveAiConfig(
        _sanitizeConfigForProviderCatalog(compactedConfig, compactedConfig.providers),
      );
      final sanitizedSaved = _sanitizeConfigForProviderCatalog(saved, saved.providers);
      final shellRules = await _localClient.saveShellRules(state.shellRules);
      final effective = await _localClient.getEffectiveAiConfig();
      final statusOverview = await _localClient.getStatusOverview();
      state = state.copyWith(
        saving: false,
        config: sanitizedSaved,
        shellRules: shellRules,
        effective: effective,
        statusOverview: statusOverview,
        noticeMessage: 'Global settings saved.',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        saving: false,
        errorMessage: 'Failed to save AI settings: $error',
      );
    }
  }

  Future<void> _loadGlobal() async {
    try {
      final rawConfig = await _localClient.getAiConfig();
      final config = _sanitizeConfigForProviderCatalog(rawConfig, rawConfig.providers);
      final shellRules = await _localClient.getShellRules();
      final effective = await _localClient.getEffectiveAiConfig();
      final statusOverview = await _localClient.getStatusOverview();
      state = state.copyWith(
        loading: false,
        config: config,
        globalConfig: config,
        shellRules: shellRules,
        effective: effective,
        statusOverview: statusOverview,
        openAiAuthStatuses: await _loadOpenAiAuthStatuses(config.providers),
        selectedSection: _coerceVisibleSection(state.selectedSection),
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        loading: false,
        errorMessage: 'Failed to load AI settings: $error',
      );
    }
  }

  Future<void> _loadWorkspace({String? requestedRoot}) async {
    try {
      final rawGlobalConfig = await _localClient.getAiConfig();
      final globalConfig = _sanitizeConfigForProviderCatalog(
        rawGlobalConfig,
        rawGlobalConfig.providers,
      );
      final recents = await _listRecentWorkspaces();
      final selectedRoot = _normalizeWorkspaceCandidate(
        requestedRoot ?? state.selectedWorkspaceRoot ?? (recents.isEmpty ? '' : recents.first.rootPath),
      );
      final statusOverview = await _localClient.getStatusOverview();

      if (selectedRoot.isEmpty) {
        state = state.copyWith(
          loading: false,
          config: const SirixAiConfig(),
          globalConfig: globalConfig,
          shellRules: const ShellRulesConfigModel(),
          effective: null,
          statusOverview: statusOverview,
          selectedWorkspaceRoot: null,
          recentWorkspaces: recents,
          openAiAuthStatuses: const {},
          hasWorkspaceSirixConfig: false,
          hasWorkspaceCodexConfig: false,
          selectedSection: _coerceVisibleSection(state.selectedSection),
          clearError: true,
        );
        return;
      }

      final payload = await _loadWorkspaceSettings(selectedRoot);
      final recentItem = _recentWorkspaceFromPayload(payload);
      final editableConfig = _sanitizeConfigForProviderCatalog(
        payload.editableConfig,
        payload.effectiveConfig.providers,
      );
      final effective = EffectiveSirixAiConfig(
        config: payload.effectiveConfig,
        workspacePath: payload.workspaceRoot,
        workspaceSource: payload.effectiveWorkspaceSource,
      );
      state = state.copyWith(
        loading: false,
        selectedWorkspaceRoot: payload.workspaceRoot,
        recentWorkspaces: _upsertRecentWorkspaceItems(recents, recentItem),
        config: editableConfig,
        globalConfig: globalConfig,
        shellRules: payload.editableShellRules,
        effective: effective,
        statusOverview: statusOverview,
        openAiAuthStatuses: await _loadOpenAiAuthStatuses(effective.config.providers),
        hasWorkspaceSirixConfig: payload.hasSirixConfig,
        hasWorkspaceCodexConfig: payload.hasCodexConfig,
        selectedSection: _coerceVisibleSection(state.selectedSection),
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        loading: false,
        config: const SirixAiConfig(),
        globalConfig: null,
        shellRules: const ShellRulesConfigModel(),
        effective: null,
        selectedWorkspaceRoot: null,
        hasWorkspaceSirixConfig: false,
        hasWorkspaceCodexConfig: false,
        selectedSection: _coerceVisibleSection(state.selectedSection),
        errorMessage: 'Failed to load workspace settings: $error',
      );
    }
  }

  Future<void> _saveWorkspace() async {
    final workspaceRoot = state.selectedWorkspaceRoot?.trim();
    if (workspaceRoot == null || workspaceRoot.isEmpty) {
      state = state.copyWith(
        saving: false,
        errorMessage: 'Choose a workspace before saving workspace settings.',
      );
      return;
    }

    final createdWorkspaceConfig = !state.hasWorkspaceSirixConfig;
    try {
      final compactedConfig = _compactAgentPermissionDeltas(
        state.config,
        globalReferenceConfig: state.globalReferenceConfig,
      );
      await _saveWorkspaceSettings(
        workspaceRoot: workspaceRoot,
        config: _sanitizeConfigForProviderCatalog(compactedConfig, state.agentPickerProviders),
        shellRules: state.shellRules,
      );
      await load(force: true, workspaceRoot: workspaceRoot);
      state = state.copyWith(
        saving: false,
        noticeMessage: createdWorkspaceConfig
            ? 'Workspace settings saved. Created a new $_sceneWorkspaceDirName directory for this workspace.'
            : 'Workspace settings saved.',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        saving: false,
        errorMessage: 'Failed to save workspace settings: $error',
      );
    }
  }

  Future<Object?> previewSystemPrompt({
    required SirixAiConfig config,
    required String agentId,
    String? cwd,
  }) {
    return _localClient.previewAgentSystemPrompt(
      config: config,
      agentId: agentId,
      cwd: cwd,
    );
  }

  void selectSection(AiSettingsSection section) {
    if (!state.visibleSections.contains(section)) {
      return;
    }
    state = state.copyWith(selectedSection: section, clearError: true, clearNotice: true);
  }

  void updateWorkspaceSearchQuery(String query) {
    state = state.copyWith(
      workspaceSearchQuery: query,
      clearError: true,
      clearNotice: true,
    );
  }

  Future<void> selectWorkspace(String candidatePath) async {
    final normalized = _normalizeWorkspaceCandidate(candidatePath);
    if (normalized.isEmpty) {
      return;
    }

    final optimisticItem = _recentWorkspaceFromPath(normalized);
    state = state.copyWith(
      selectedWorkspaceRoot: normalized,
      recentWorkspaces: _upsertRecentWorkspaceItems(state.recentWorkspaces, optimisticItem),
      clearError: true,
      clearNotice: true,
    );

    try {
      // Workspace selection should feel immediate even before the first save
      // creates a local .sirix directory, so we optimistically bump the recent
      // list in memory first and let backend persistence follow in the
      // background for the durable 50-entry registry.
      await _upsertRecentWorkspace(normalized);
    } catch (error) {
      AppLogger.warn('[WORKSPACE_SETTINGS] failed to persist recent workspace path=$normalized error=$error');
    }

    await load(force: true, workspaceRoot: normalized);
  }

  void updateCliPrompt(String prompt) {
    state = state.copyWith(
      config: state.config.copyWith(
        cli: state.config.cli.copyWith(supplementalSystemPrompt: prompt),
      ),
      clearError: true,
      clearNotice: true,
    );
  }

  void updateCloseModelWithoutConfirmation(bool value) {
    state = state.copyWith(
      config: state.config.copyWith(
        cli: state.config.cli.copyWith(closeModelWithoutConfirmation: value),
      ),
      clearError: true,
      clearNotice: true,
    );
  }

  void upsertProvider(AiProviderConfig provider) {
    final next = _upsertById(state.config.providers, provider, (item) => item.id);
    final nextStatuses = Map<String, OpenAiAuthStatus>.from(state.openAiAuthStatuses);
    if (!_supportsOpenAiAuth(provider)) {
      nextStatuses.remove(provider.id);
    }
    state = state.copyWith(
      config: _reconcileDefaultAgent(
        state.config.copyWith(providers: next),
        providerCatalog: next,
      ),
      openAiAuthStatuses: nextStatuses,
      clearError: true,
      clearNotice: true,
    );
  }

  void removeProvider(String providerId) {
    final providers = state.config.providers
        .where((item) => item.id != providerId)
        .toList(growable: false);
    final agents = state.config.agents
        .where((item) => item.providerId != providerId)
        .toList(growable: false);
    final nextStatuses = Map<String, OpenAiAuthStatus>.from(state.openAiAuthStatuses)
      ..remove(providerId);
    state = state.copyWith(
      config: _reconcileDefaultAgent(
        state.config.copyWith(
          providers: providers,
          agents: agents,
        ),
        providerCatalog: providers,
      ),
      openAiAuthStatuses: nextStatuses,
      clearError: true,
      clearNotice: true,
    );
  }

  void updateProviderDefaultContextWindow({
    required String providerId,
    required int? contextWindow,
  }) {
    final providers = [
      for (final provider in state.config.providers)
        if (provider.id == providerId)
          provider.copyWith(defaultContextWindow: contextWindow)
        else
          provider,
    ];
    state = state.copyWith(
      config: _reconcileDefaultAgent(
        state.config.copyWith(providers: providers),
        providerCatalog: providers,
      ),
      clearError: true,
      clearNotice: true,
    );
  }

  Future<void> discoverProviderModels(AiProviderConfig provider) async {
    final providerId = provider.id.trim();
    if (providerId.isEmpty || state.discoveringProviderIds.contains(providerId)) {
      return;
    }

    state = state.copyWith(
      discoveringProviderIds: [...state.discoveringProviderIds, providerId],
      clearError: true,
      clearNotice: true,
    );
    AppLogger.info(
      '[AI_PROVIDER_DISCOVERY] start provider_id=$providerId base_url=${provider.baseUrl}',
    );

    try {
      final discovered = await _localClient.discoverProviderModels(provider);
      final existingModelsById = {
        for (final model in provider.models) model.id: model,
      };
      final merged = discovered
          .map((model) {
            final existing = existingModelsById[model.id];
            if (existing == null) {
              return model;
            }
            return model.copyWith(enabled: existing.enabled);
          })
          .toList(growable: false);
      upsertProvider(provider.copyWith(models: merged));
      state = state.copyWith(
        noticeMessage: merged.isEmpty
            ? 'No models were returned for ${provider.name}.'
            : 'Fetched ${merged.length} models for ${provider.name}. Review inferred capabilities before saving.',
        clearError: true,
      );
      AppLogger.info(
        '[AI_PROVIDER_DISCOVERY] success provider_id=$providerId model_count=${merged.length}',
      );
    } catch (error, stackTrace) {
      state = state.copyWith(
        errorMessage: 'Failed to fetch models for ${provider.name}: $error',
      );
      AppLogger.warn('[AI_PROVIDER_DISCOVERY] failed provider_id=$providerId error=$error');
      AppLogger.warn('[AI_PROVIDER_DISCOVERY] stack provider_id=$providerId stack=$stackTrace');
    } finally {
      state = state.copyWith(
        discoveringProviderIds: state.discoveringProviderIds
            .where((item) => item != providerId)
            .toList(growable: false),
      );
    }
  }

  Future<void> refreshOpenAiAuthStatus(String providerId) async {
    final trimmedProviderId = providerId.trim();
    if (trimmedProviderId.isEmpty) {
      return;
    }

    try {
      final status = await _localClient.getOpenAiAuthStatus(trimmedProviderId);
      final nextStatuses = Map<String, OpenAiAuthStatus>.from(state.openAiAuthStatuses)
        ..[trimmedProviderId] = status;
      state = state.copyWith(
        openAiAuthStatuses: nextStatuses,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Failed to load OpenAI auth status: $error',
      );
    }
  }

  Future<Uri> startOpenAiAuthLogin(String providerId) async {
    final trimmedProviderId = providerId.trim();
    await _setProviderAuthBusy(trimmedProviderId, true);
    try {
      final authUrl = await _localClient.startOpenAiAuthLogin(trimmedProviderId);
      await refreshOpenAiAuthStatus(trimmedProviderId);
      unawaited(_pollOpenAiAuthStatus(trimmedProviderId));
      return authUrl;
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Failed to start OpenAI browser login: $error',
      );
      rethrow;
    } finally {
      await _setProviderAuthBusy(trimmedProviderId, false);
    }
  }

  Future<void> importOpenAiAuthJson({
    required String providerId,
    required Map<String, dynamic> authJson,
  }) async {
    final trimmedProviderId = providerId.trim();
    await _setProviderAuthBusy(trimmedProviderId, true);
    try {
      await _localClient.importOpenAiAuthJson(
        providerId: trimmedProviderId,
        authJson: authJson,
      );
      await refreshOpenAiAuthStatus(trimmedProviderId);
      state = state.copyWith(
        noticeMessage: 'OpenAI auth JSON imported for $trimmedProviderId.',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Failed to import OpenAI auth JSON: $error',
      );
      rethrow;
    } finally {
      await _setProviderAuthBusy(trimmedProviderId, false);
    }
  }

  Future<void> logoutOpenAiAuth(String providerId) async {
    final trimmedProviderId = providerId.trim();
    await _setProviderAuthBusy(trimmedProviderId, true);
    try {
      await _localClient.logoutOpenAiAuth(trimmedProviderId);
      await refreshOpenAiAuthStatus(trimmedProviderId);
      state = state.copyWith(
        noticeMessage: 'OpenAI auth removed for $trimmedProviderId.',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Failed to sign out OpenAI auth: $error',
      );
      rethrow;
    } finally {
      await _setProviderAuthBusy(trimmedProviderId, false);
    }
  }

  void upsertModel({
    required String providerId,
    required AiModelConfig model,
  }) {
    final providers = [
      for (final provider in state.config.providers)
        if (provider.id == providerId)
          provider.copyWith(
            models: _upsertById(provider.models, model, (item) => item.id),
          )
        else
          provider,
    ];
    state = state.copyWith(
      config: _reconcileDefaultAgent(
        state.config.copyWith(providers: providers),
        providerCatalog: providers,
      ),
      clearError: true,
      clearNotice: true,
    );
  }

  void removeModel({
    required String providerId,
    required String modelId,
  }) {
    final providers = [
      for (final provider in state.config.providers)
        if (provider.id == providerId)
          provider.copyWith(
            models:
                provider.models.where((item) => item.id != modelId).toList(growable: false),
          )
        else
          provider,
    ];
    final agents = state.config.agents
        .where((item) => !(item.providerId == providerId && item.modelId == modelId))
        .toList(growable: false);
    state = state.copyWith(
      config: _reconcileDefaultAgent(
        state.config.copyWith(
          providers: providers,
          agents: agents,
        ),
        providerCatalog: providers,
      ),
      clearError: true,
      clearNotice: true,
    );
  }

  void setDefaultModel({
    required String providerId,
    required String modelId,
  }) {
    state = state.copyWith(
      config: _reconcileDefaultAgent(
        state.config,
        providerCatalog: state.agentPickerProviders,
        preferredProviderId: providerId,
        preferredModelId: modelId,
      ),
      clearError: true,
      clearNotice: true,
    );
  }

  void upsertSkill(SkillConfigModel skill) {
    final next = _upsertById(state.config.skills, skill, (item) => item.id);
    state = state.copyWith(
      config: state.config.copyWith(skills: next),
      clearError: true,
      clearNotice: true,
    );
  }

  void removeSkill(String skillId) {
    final skills =
        state.config.skills.where((item) => item.id != skillId).toList(growable: false);
    final agents = [
      for (final agent in state.config.agents)
        agent.copyWith(
          skillIds: agent.skillIds.where((item) => item != skillId).toList(growable: false),
        ),
    ];
    state = state.copyWith(
      config: state.config.copyWith(skills: skills, agents: agents),
      clearError: true,
      clearNotice: true,
    );
  }

  void upsertMcpServer(McpServerConfigModel server) {
    final next = _upsertById(state.config.mcpServers, server, (item) => item.id);
    state = state.copyWith(
      config: state.config.copyWith(mcpServers: next),
      clearError: true,
      clearNotice: true,
    );
  }

  void updateMcpGlobal(McpGlobalConfigModel mcp) {
    state = state.copyWith(
      config: state.config.copyWith(mcp: mcp),
      clearError: true,
      clearNotice: true,
    );
  }

  void removeMcpServer(String serverId) {
    final mcpServers =
        state.config.mcpServers.where((item) => item.id != serverId).toList(growable: false);
    final agents = [
      for (final agent in state.config.agents)
        agent.copyWith(
          mcpServerIds: agent.mcpServerIds.where((item) => item != serverId).toList(growable: false),
        ),
    ];
    state = state.copyWith(
      config: state.config.copyWith(mcpServers: mcpServers, agents: agents),
      clearError: true,
      clearNotice: true,
    );
  }

  void upsertAgent(AgentConfigModel agent) {
    final next = _upsertById(state.config.agents, agent, (item) => item.id);
    state = state.copyWith(
      config: _reconcileDefaultAgent(
        state.config.copyWith(agents: next),
        providerCatalog: state.agentPickerProviders,
      ),
      clearError: true,
      clearNotice: true,
    );
  }

  void removeAgent(String agentId) {
    if (agentId == _defaultAgentId) {
      return;
    }
    final agents =
        state.config.agents.where((item) => item.id != agentId).toList(growable: false);
    final cleanedAgents = [
      for (final agent in agents)
        agent.copyWith(
          subAgentIds: agent.subAgentIds.where((item) => item != agentId).toList(growable: false),
        ),
    ];
    state = state.copyWith(
      config: _reconcileDefaultAgent(
        state.config.copyWith(agents: cleanedAgents),
        providerCatalog: state.agentPickerProviders,
      ),
      clearError: true,
      clearNotice: true,
    );
  }

  void updateShellRules(ShellRulesConfigModel shellRules) {
    state = state.copyWith(
      shellRules: shellRules,
      clearError: true,
      clearNotice: true,
    );
  }

  void updateBuiltinApprovals(CapabilityRulesConfigModel approvals) {
    state = state.copyWith(
      config: state.config.copyWith(builtinApprovals: approvals),
      clearError: true,
      clearNotice: true,
    );
  }

  void updateSkillApprovals(CapabilityRulesConfigModel approvals) {
    state = state.copyWith(
      config: state.config.copyWith(skillApprovals: approvals),
      clearError: true,
      clearNotice: true,
    );
  }

  void updateMcpApprovals(CapabilityRulesConfigModel approvals) {
    state = state.copyWith(
      config: state.config.copyWith(mcpApprovals: approvals),
      clearError: true,
      clearNotice: true,
    );
  }

  String createStableId(String prefix) {
    final micros = DateTime.now().microsecondsSinceEpoch;
    return '$prefix-$micros';
  }

  SirixAiConfig _reconcileDefaultAgent(
    SirixAiConfig config, {
    List<AiProviderConfig>? providerCatalog,
    String? preferredProviderId,
    String? preferredModelId,
  }) {
    // Provider/Model 页面现在直接维护 Sirix CLI 的默认 Codex Agent 模型。
    // 运行时默认启动链路以内置 `codex` Agent 为入口，所以这里把页面上的
    // 默认模型选择同步收敛到 `codex`，避免再引入第二套默认模型存储。
    final providers = providerCatalog ?? config.providers;
    final existingDefaultAgent = _firstWhereOrNull(
      config.agents,
      (item) => item.id == _defaultAgentId,
    );
    final eligibleModels = [
      for (final provider in providers)
        if (provider.enabled)
          for (final model in provider.models)
            if (model.enabled && model.modelKind == ModelKind.text)
              (providerId: provider.id, modelId: model.id),
    ];

    ({String providerId, String modelId})? selected;
    if (preferredProviderId != null &&
        preferredModelId != null &&
        eligibleModels.any(
          (item) => item.providerId == preferredProviderId && item.modelId == preferredModelId,
        )) {
      selected = (providerId: preferredProviderId, modelId: preferredModelId);
    } else if (existingDefaultAgent != null &&
        eligibleModels.any(
          (item) =>
              item.providerId == existingDefaultAgent.providerId &&
              item.modelId == existingDefaultAgent.modelId,
        )) {
      selected = (
        providerId: existingDefaultAgent.providerId,
        modelId: existingDefaultAgent.modelId,
      );
    } else {
      selected = eligibleModels.isEmpty ? null : eligibleModels.first;
    }

    final otherAgents =
        config.agents.where((item) => item.id != _defaultAgentId).toList(growable: false);
    if (selected == null) {
      return config.copyWith(agents: otherAgents);
    }

    final defaultAgent = (existingDefaultAgent ?? _buildDefaultAgent()).copyWith(
      id: _defaultAgentId,
      name: existingDefaultAgent?.name ?? 'Codex',
      providerId: selected.providerId,
      modelId: selected.modelId,
      enabled: true,
      systemPrompt: '',
      builtinToolIds: kBuiltinToolCatalog,
    );

    return config.copyWith(agents: [defaultAgent, ...otherAgents]);
  }

  AgentConfigModel _buildDefaultAgent() {
    return const AgentConfigModel(
      id: _defaultAgentId,
      name: 'Codex',
      description: 'Built-in Codex agent with the standard Codex system prompt.',
      providerId: '',
      modelId: '',
      approvalMode: ApprovalMode.ask,
      builtinToolIds: kBuiltinToolCatalog,
      enabled: true,
    );
  }

  Future<Map<String, OpenAiAuthStatus>> _loadOpenAiAuthStatuses(
    List<AiProviderConfig> providers,
  ) async {
    final entries = <String, OpenAiAuthStatus>{};
    for (final provider in providers) {
      if (!_supportsOpenAiAuth(provider)) {
        continue;
      }
      try {
        entries[provider.id] = await _localClient.getOpenAiAuthStatus(provider.id);
      } catch (error) {
        AppLogger.warn(
          '[OPENAI_AUTH] failed to preload status provider_id=${provider.id} error=$error',
        );
      }
    }
    return entries;
  }

  bool _supportsOpenAiAuth(AiProviderConfig provider) {
    return provider.kind == ProviderKind.openAiCodexOauth;
  }

  Future<void> _pollOpenAiAuthStatus(String providerId) async {
    for (var attempt = 0; attempt < 120; attempt += 1) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await refreshOpenAiAuthStatus(providerId);
      final status = state.openAiAuthStatuses[providerId];
      if (status == null || !status.loginInProgress || status.authenticated) {
        return;
      }
    }
  }

  Future<void> _setProviderAuthBusy(String providerId, bool busy) async {
    final nextBusy = [...state.authBusyProviderIds];
    nextBusy.remove(providerId);
    if (busy) {
      nextBusy.add(providerId);
    }
    state = state.copyWith(
      authBusyProviderIds: nextBusy,
      clearError: true,
      clearNotice: true,
    );
  }

  AiSettingsSection _coerceVisibleSection(AiSettingsSection section) {
    if (state.visibleSections.contains(section)) {
      return section;
    }
    return _defaultSectionForScope(_scope);
  }

  Future<List<AiRecentWorkspace>> _listRecentWorkspaces() async {
    try {
      return (await _localClient.getRecentWorkspaces())
          .map(_recentWorkspaceFromEntry)
          .toList(growable: false);
    } catch (error) {
      AppLogger.warn('[WORKSPACE_SETTINGS] failed to load recents error=$error');
      return state.recentWorkspaces;
    }
  }

  Future<void> _upsertRecentWorkspace(String path) async {
    await _localClient.selectWorkspace(path);
  }

  Future<_WorkspaceSettingsPayload> _loadWorkspaceSettings(String workspaceRoot) async {
    try {
      return _WorkspaceSettingsPayload.fromResponse(
        await _localClient.getWorkspaceSettings(workspaceRoot),
      );
    } catch (error) {
      if (!_shouldFallbackToEffectiveOnlyWorkspace(error)) {
        rethrow;
      }
      AppLogger.warn('[WORKSPACE_SETTINGS] falling back to effective-only load root=$workspaceRoot error=$error');
      final effective = await _localClient.getEffectiveAiConfig(cwd: workspaceRoot);
      final effectiveSource = effective.workspaceSource;
      return _WorkspaceSettingsPayload(
        workspaceRoot: workspaceRoot,
        editableConfig: const SirixAiConfig(),
        editableShellRules: const ShellRulesConfigModel(),
        effectiveConfig: effective.config,
        effectiveShellRules: const ShellRulesConfigModel(),
        effectiveWorkspaceSource: effectiveSource,
        hasSirixConfig: _containsSirixWorkspaceDir(effectiveSource),
        hasCodexConfig: (effectiveSource ?? '').contains('.codex'),
      );
    }
  }

  Future<void> _saveWorkspaceSettings({
    required String workspaceRoot,
    required SirixAiConfig config,
    required ShellRulesConfigModel shellRules,
  }) async {
    await _localClient.saveWorkspaceSettings(
      path: workspaceRoot,
      editableConfig: _projectWorkspaceEditableConfig(config),
      editableShellRules: shellRules,
    );
  }
}

List<T> _upsertById<T>(
  List<T> items,
  T incoming,
  String Function(T) getId,
) {
  final incomingId = getId(incoming);
  final index = items.indexWhere((item) => getId(item) == incomingId);
  if (index < 0) {
    return [...items, incoming];
  }

  final next = [...items];
  next[index] = incoming;
  return next;
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) {
      return item;
    }
  }
  return null;
}

AiSettingsSection _defaultSectionForScope(AiSettingsScope scope) {
  return switch (scope) {
    AiSettingsScope.global => AiSettingsSection.cli,
    AiSettingsScope.workspace => AiSettingsSection.skills,
  };
}

WorkspaceEditableAiConfig _projectWorkspaceEditableConfig(SirixAiConfig config) {
  return WorkspaceEditableAiConfig(
    version: config.version,
    skills: config.skills,
    mcp: config.mcp,
    builtinApprovals: config.builtinApprovals,
    skillApprovals: config.skillApprovals,
    mcpApprovals: config.mcpApprovals,
    mcpServers: config.mcpServers,
    agents: config.agents,
  );
}

SirixAiConfig _sanitizeConfigForProviderCatalog(
  SirixAiConfig config,
  List<AiProviderConfig> providerCatalog,
) {
  final enabledProviders = providerCatalog.where((provider) => provider.enabled).toList(growable: false);
  final sanitizedAgents = [
    for (final agent in config.agents)
      agent.copyWith(
        fallbackProviderId: _sanitizeFallbackProviderId(agent, enabledProviders),
        fallbackModelId: _sanitizeFallbackModelId(agent, enabledProviders),
      ),
  ];
  return config.copyWith(agents: sanitizedAgents);
}

SirixAiConfig _compactAgentPermissionDeltas(
  SirixAiConfig config, {
  required SirixAiConfig globalReferenceConfig,
}) {
  final builtinBase = globalReferenceConfig.builtinApprovals;
  final skillBase = globalReferenceConfig.skillApprovals;
  final mcpBase = globalReferenceConfig.mcpApprovals;
  final compactedAgents = [
    for (final agent in config.agents)
      agent.copyWith(
        // Agent approval configs are persisted as deltas against the global
        // policy layer because the runtime merges global -> agent -> workspace.
        // Re-compacting on every save keeps older fully-expanded configs from
        // being written back indefinitely once the UI has loaded them.
        builtinApprovals: diffCapabilityRulesOverlay(
          builtinBase,
          mergeCapabilityRules(builtinBase, agent.builtinApprovals),
        ),
        skillApprovals: diffCapabilityRulesOverlay(
          skillBase,
          mergeCapabilityRules(skillBase, agent.skillApprovals),
        ),
        mcpApprovals: diffCapabilityRulesOverlay(
          mcpBase,
          mergeCapabilityRules(mcpBase, agent.mcpApprovals),
        ),
      ),
  ];
  return config.copyWith(agents: compactedAgents);
}

String _sanitizeFallbackProviderId(
  AgentConfigModel agent,
  List<AiProviderConfig> enabledProviders,
) {
  final fallbackProviderId = agent.fallbackProviderId.trim();
  if (fallbackProviderId.isEmpty) {
    return '';
  }
  final provider = _firstWhereOrNull(
    enabledProviders,
    (candidate) => candidate.id == fallbackProviderId,
  );
  final fallbackModels = provider == null
      ? const <AiModelConfig>[]
      : provider.models
            .where((model) => model.enabled && model.modelKind == ModelKind.text)
            .toList(growable: false);
  return fallbackModels.isEmpty ? '' : fallbackProviderId;
}

String _sanitizeFallbackModelId(
  AgentConfigModel agent,
  List<AiProviderConfig> enabledProviders,
) {
  final fallbackProviderId = _sanitizeFallbackProviderId(agent, enabledProviders);
  if (fallbackProviderId.isEmpty) {
    return '';
  }
  final provider = _firstWhereOrNull(
    enabledProviders,
    (candidate) => candidate.id == fallbackProviderId,
  );
  final fallbackModels = provider == null
      ? const <AiModelConfig>[]
      : provider.models
            .where((model) => model.enabled && model.modelKind == ModelKind.text)
            .toList(growable: false);
  final fallbackModelId = agent.fallbackModelId.trim();
  if (fallbackModels.isEmpty) {
    return '';
  }
  if (fallbackModels.any((model) => model.id == fallbackModelId)) {
    return fallbackModelId;
  }
  return fallbackModels.first.id;
}

bool _shouldFallbackToEffectiveOnlyWorkspace(Object error) {
  final message = error.toString();
  return message.contains('HTTP 404');
}

String _normalizeWorkspaceCandidate(String candidatePath) {
  var normalized = candidatePath.trim();
  if (normalized.isEmpty) {
    return '';
  }

  // Preserve Windows/UNC filesystem roots exactly as-is. Trimming their
  // trailing separator would turn `C:\` into the relative-looking `C:` and
  // break workspace selection for users who intentionally target a drive root.
  if (_isWindowsDriveRoot(normalized) || _isUncRoot(normalized)) {
    return normalized;
  }

  while (normalized.length > 1 &&
      (normalized.endsWith('/') || normalized.endsWith('\\'))) {
    normalized = normalized.substring(0, normalized.length - 1);
  }

  final segments = normalized.split(RegExp(r'[\\/]'));
  if (segments.isNotEmpty &&
      (segments.last == '.sirix' || segments.last == '.sirix-debug')) {
    final directory = Directory(normalized);
    final parentPath = directory.parent.path;
    return parentPath == normalized ? normalized : parentPath;
  }
  return normalized;
}

bool _containsSirixWorkspaceDir(String? source) {
  final raw = source ?? '';
  return raw.contains('.sirix') || raw.contains('.sirix-debug');
}

const _sceneWorkspaceDirName =
    String.fromEnvironment('SIRIX_SCENE', defaultValue: 'debug') == 'release'
    ? '.sirix'
    : '.sirix-debug';

bool _isWindowsDriveRoot(String path) {
  return RegExp(r'^[a-zA-Z]:[\\/]$').hasMatch(path);
}

bool _isUncRoot(String path) {
  final normalized = path.replaceAll('/', r'\');
  return RegExp(r'^\\\\[^\\]+\\[^\\]+\\?$').hasMatch(normalized);
}

String _workspaceLabel(String rootPath) {
  final trimmed = rootPath.trim();
  if (trimmed.isEmpty) {
    return 'Workspace';
  }
  final segments = trimmed.split(RegExp(r'[\\/]')).where((item) => item.isNotEmpty).toList();
  return segments.isEmpty ? trimmed : segments.last;
}

AiRecentWorkspace _recentWorkspaceFromPath(String rootPath) {
  return AiRecentWorkspace(
    rootPath: rootPath,
    label: _workspaceLabel(rootPath),
  );
}

AiRecentWorkspace _recentWorkspaceFromPayload(_WorkspaceSettingsPayload payload) {
  return AiRecentWorkspace(
    rootPath: payload.workspaceRoot,
    label: _workspaceLabel(payload.workspaceRoot),
    hasSirixConfig: payload.hasSirixConfig,
    hasCodexConfig: payload.hasCodexConfig,
    subtitle: payload.effectiveWorkspaceSource,
  );
}

AiRecentWorkspace _recentWorkspaceFromEntry(RecentWorkspaceEntry entry) {
  final normalizedRoot = _normalizeWorkspaceCandidate(entry.workspaceRoot);
  return AiRecentWorkspace(
    rootPath: normalizedRoot,
    label: entry.displayName.trim().isNotEmpty
        ? entry.displayName
        : _workspaceLabel(normalizedRoot),
    hasSirixConfig: entry.hasSirixConfig,
    hasCodexConfig: entry.hasCodexConfig,
    lastOpenedAt:
        entry.lastSelectedAt.trim().isEmpty ? null : DateTime.tryParse(entry.lastSelectedAt),
  );
}

SirixAiConfig _workspaceEditableToSirixConfig(WorkspaceEditableAiConfig config) {
  return SirixAiConfig(
    version: config.version,
    skills: config.skills,
    mcp: config.mcp,
    builtinApprovals: config.builtinApprovals,
    skillApprovals: config.skillApprovals,
    mcpApprovals: config.mcpApprovals,
    mcpServers: config.mcpServers,
    agents: config.agents,
  );
}

List<AiRecentWorkspace> _upsertRecentWorkspaceItems(
  List<AiRecentWorkspace> items,
  AiRecentWorkspace incoming,
) {
  final normalizedIncoming = _normalizeWorkspaceCandidate(incoming.rootPath);
  final deduped = [
    incoming.copyWith(rootPath: normalizedIncoming),
    for (final item in items)
      if (_normalizeWorkspaceCandidate(item.rootPath) != normalizedIncoming) item,
  ];
  return deduped.take(_maxRecentWorkspaces).toList(growable: false);
}

final aiSettingsViewModelProvider =
    StateNotifierProvider.family<AiSettingsViewModel, AiSettingsState, AiSettingsScope>((ref, scope) {
  final localClient = ref.watch(desktopLocalClientProvider);
  return AiSettingsViewModel(localClient, scope);
});
