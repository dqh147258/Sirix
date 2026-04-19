import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

import 'ai_settings_state.dart';

const String _defaultAgentId = 'codex';

class AiSettingsViewModel extends BaseViewModel<AiSettingsState> {
  AiSettingsViewModel(this._localClient) : super(const AiSettingsState());

  final DesktopLocalClient _localClient;
  bool _loaded = false;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) {
      return;
    }

    _loaded = true;
    state = state.copyWith(loading: true, clearError: true, clearNotice: true);
    try {
      final config = await _localClient.getAiConfig();
      final shellRules = await _localClient.getShellRules();
      final effective = await _localClient.getEffectiveAiConfig();
      final statusOverview = await _localClient.getStatusOverview();
      state = state.copyWith(
        loading: false,
        config: config,
        shellRules: shellRules,
        effective: effective,
        statusOverview: statusOverview,
        openAiAuthStatuses: await _loadOpenAiAuthStatuses(config.providers),
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        loading: false,
        errorMessage: 'Failed to load AI settings: $error',
      );
    }
  }

  Future<void> save() async {
    if (state.saving) {
      return;
    }

    state = state.copyWith(saving: true, clearError: true, clearNotice: true);
    try {
      // Keep config.toml and shell-rules.json saves in one explicit transaction-like
      // flow so the desktop settings page reflects the exact pair of artifacts the
      // runtime will read on the next session launch.
      final saved = await _localClient.saveAiConfig(state.config);
      final shellRules = await _localClient.saveShellRules(state.shellRules);
      final effective = await _localClient.getEffectiveAiConfig();
      final statusOverview = await _localClient.getStatusOverview();
      state = state.copyWith(
        saving: false,
        config: saved,
        shellRules: shellRules,
        effective: effective,
        statusOverview: statusOverview,
        noticeMessage: 'AI settings saved.',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        saving: false,
        errorMessage: 'Failed to save AI settings: $error',
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
    state = state.copyWith(selectedSection: section, clearError: true, clearNotice: true);
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
      config: _reconcileDefaultAgent(state.config.copyWith(providers: next)),
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
      config: _reconcileDefaultAgent(state.config.copyWith(
        providers: providers,
        agents: agents,
      )),
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
      config: _reconcileDefaultAgent(state.config.copyWith(providers: providers)),
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
      config: _reconcileDefaultAgent(state.config.copyWith(providers: providers)),
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
      config: _reconcileDefaultAgent(state.config.copyWith(
        providers: providers,
        agents: agents,
      )),
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
      config: _reconcileDefaultAgent(state.config.copyWith(agents: next)),
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
      config: _reconcileDefaultAgent(state.config.copyWith(agents: cleanedAgents)),
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
    String? preferredProviderId,
    String? preferredModelId,
  }) {
    // Provider/Model 页面现在直接维护 Sirix CLI 的默认 Codex Agent 模型。
    // 运行时默认启动链路以内置 `codex` Agent 为入口，所以这里把页面上的
    // 默认模型选择同步收敛到 `codex`，避免再引入第二套默认模型存储。
    final providers = config.providers;
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

final aiSettingsViewModelProvider =
    StateNotifierProvider<AiSettingsViewModel, AiSettingsState>((ref) {
  final localClient = ref.watch(desktopLocalClientProvider);
  return AiSettingsViewModel(localClient);
});
