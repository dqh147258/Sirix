import 'package:flutter/foundation.dart';

import 'package:infra_api/infra_api.dart';

const Object _aiSettingsUnset = Object();

enum AiSettingsScope {
  global,
  workspace,
}

enum AiSettingsSection {
  cli,
  providers,
  skills,
  mcp,
  agents,
  permissions,
}

@immutable
class AiRecentWorkspace {
  const AiRecentWorkspace({
    required this.rootPath,
    required this.label,
    this.subtitle,
    this.hasSirixConfig = false,
    this.hasCodexConfig = false,
    this.lastOpenedAt,
  });

  final String rootPath;
  final String label;
  final String? subtitle;
  final bool hasSirixConfig;
  final bool hasCodexConfig;
  final DateTime? lastOpenedAt;

  String get searchableText => [label, subtitle ?? '', rootPath].join(' ').toLowerCase();

  AiRecentWorkspace copyWith({
    String? rootPath,
    String? label,
    Object? subtitle = _aiSettingsUnset,
    bool? hasSirixConfig,
    bool? hasCodexConfig,
    Object? lastOpenedAt = _aiSettingsUnset,
  }) {
    return AiRecentWorkspace(
      rootPath: rootPath ?? this.rootPath,
      label: label ?? this.label,
      subtitle: identical(subtitle, _aiSettingsUnset) ? this.subtitle : subtitle as String?,
      hasSirixConfig: hasSirixConfig ?? this.hasSirixConfig,
      hasCodexConfig: hasCodexConfig ?? this.hasCodexConfig,
      lastOpenedAt: identical(lastOpenedAt, _aiSettingsUnset)
          ? this.lastOpenedAt
          : lastOpenedAt as DateTime?,
    );
  }
}

@immutable
class AiSettingsState {
  const AiSettingsState({
    this.scope = AiSettingsScope.global,
    this.loading = false,
    this.saving = false,
    this.discoveringProviderIds = const [],
    this.authBusyProviderIds = const [],
    this.openAiAuthStatuses = const {},
    this.errorMessage,
    this.noticeMessage,
    this.selectedSection = AiSettingsSection.cli,
    this.config = const SirixAiConfig(),
    this.globalConfig,
    this.shellRules = const ShellRulesConfigModel(),
    this.effective,
    this.statusOverview,
    this.selectedWorkspaceRoot,
    this.workspaceSearchQuery = '',
    this.recentWorkspaces = const [],
    this.hasWorkspaceSirixConfig = false,
    this.hasWorkspaceCodexConfig = false,
  });

  final AiSettingsScope scope;
  final bool loading;
  final bool saving;
  final List<String> discoveringProviderIds;
  final List<String> authBusyProviderIds;
  final Map<String, OpenAiAuthStatus> openAiAuthStatuses;
  final String? errorMessage;
  final String? noticeMessage;
  final AiSettingsSection selectedSection;
  final SirixAiConfig config;
  final SirixAiConfig? globalConfig;
  final ShellRulesConfigModel shellRules;
  final EffectiveSirixAiConfig? effective;
  final LocalStatusOverview? statusOverview;
  final String? selectedWorkspaceRoot;
  final String workspaceSearchQuery;
  final List<AiRecentWorkspace> recentWorkspaces;
  final bool hasWorkspaceSirixConfig;
  final bool hasWorkspaceCodexConfig;

  bool get isWorkspaceScope => scope == AiSettingsScope.workspace;

  bool get hasSelectedWorkspace =>
      selectedWorkspaceRoot != null && selectedWorkspaceRoot!.trim().isNotEmpty;

  List<AiSettingsSection> get visibleSections => isWorkspaceScope
      ? const [
          AiSettingsSection.skills,
          AiSettingsSection.mcp,
          AiSettingsSection.agents,
          AiSettingsSection.permissions,
        ]
      : AiSettingsSection.values;

  List<AiProviderConfig> get agentPickerProviders => isWorkspaceScope
      ? ((globalConfig ?? effective?.config)?.providers ?? const <AiProviderConfig>[])
      : config.providers;

  /// Workspace Settings keeps the raw global catalog side-by-side with the raw
  /// workspace overlay. Resource definitions (skills / MCP servers / agents)
  /// are additive, while permission surfaces still layer by priority on top of
  /// those combined catalogs.
  SirixAiConfig get globalReferenceConfig => globalConfig ?? config;

  /// Build the effective in-memory config that the current form edits imply.
  /// This mirrors the Desktop Server merge contract closely enough for UI-only
  /// previews: global providers remain authoritative, workspace resource
  /// catalogs add/override by id, and permission layers still merge with
  /// workspace priority above the global defaults.
  SirixAiConfig get effectiveEditableConfig {
    if (!isWorkspaceScope) {
      return config;
    }

    final global = globalReferenceConfig;
    return global.copyWith(
      skills: _mergeById(global.skills, config.skills, (item) => item.id),
      mcp: _isDefaultMcpGlobalConfig(config.mcp) ? global.mcp : config.mcp,
      builtinApprovals: _mergeCapabilityRulesLikeServer(
        global.builtinApprovals,
        config.builtinApprovals,
      ),
      skillApprovals: _mergeCapabilityRulesLikeServer(
        global.skillApprovals,
        config.skillApprovals,
      ),
      mcpApprovals: _mergeCapabilityRulesLikeServer(
        global.mcpApprovals,
        config.mcpApprovals,
      ),
      mcpServers: _mergeById(
        global.mcpServers,
        config.mcpServers,
        (item) => item.id,
      ),
      agents: _mergeById(global.agents, config.agents, (item) => item.id),
    );
  }

  SirixAiConfig get promptPreviewBaseConfig => effectiveEditableConfig;

  List<SkillConfigModel> get visibleSkills => effectiveEditableConfig.skills;

  List<McpServerConfigModel> get visibleMcpServers => effectiveEditableConfig.mcpServers;

  List<AgentConfigModel> get visibleAgents => effectiveEditableConfig.agents;

  bool workspaceOwnsSkill(String skillId) =>
      config.skills.any((item) => item.id == skillId);

  bool workspaceOwnsMcpServer(String serverId) =>
      config.mcpServers.any((item) => item.id == serverId);

  bool workspaceOwnsAgent(String agentId) =>
      config.agents.any((item) => item.id == agentId);

  bool globalOwnsSkill(String skillId) =>
      globalReferenceConfig.skills.any((item) => item.id == skillId);

  bool globalOwnsMcpServer(String serverId) =>
      globalReferenceConfig.mcpServers.any((item) => item.id == serverId);

  bool globalOwnsAgent(String agentId) =>
      globalReferenceConfig.agents.any((item) => item.id == agentId);

  String? sourceLabelForResource({
    required bool workspaceOwned,
    required bool globalOwned,
  }) {
    if (!isWorkspaceScope) {
      return null;
    }
    if (workspaceOwned && globalOwned) {
      return 'Workspace Override';
    }
    if (workspaceOwned) {
      return 'Workspace';
    }
    if (globalOwned) {
      return 'Global';
    }
    return null;
  }

  List<AiRecentWorkspace> get filteredRecentWorkspaces {
    final query = workspaceSearchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return recentWorkspaces;
    }
    return recentWorkspaces
        .where((item) => item.searchableText.contains(query))
        .toList(growable: false);
  }

  String? get workspaceStatusMessage {
    if (!isWorkspaceScope || !hasSelectedWorkspace) {
      return null;
    }
    if (!hasWorkspaceSirixConfig) {
      return hasWorkspaceCodexConfig
          ? 'This workspace currently inherits global settings only. A local $_sceneWorkspaceDirName directory will be created on first save; existing .codex config stays informational in this screen.'
          : 'This workspace does not have a local $_sceneWorkspaceDirName directory yet. The first Workspace Settings save will create one automatically.';
    }
    return 'Workspace-local settings are stored under ${selectedWorkspaceRoot!}/$_sceneWorkspaceDirName and merged on top of your global defaults.';
  }

  AiSettingsState copyWith({
    AiSettingsScope? scope,
    bool? loading,
    bool? saving,
    List<String>? discoveringProviderIds,
    List<String>? authBusyProviderIds,
    Map<String, OpenAiAuthStatus>? openAiAuthStatuses,
    String? errorMessage,
    String? noticeMessage,
    AiSettingsSection? selectedSection,
    SirixAiConfig? config,
    Object? globalConfig = _aiSettingsUnset,
    ShellRulesConfigModel? shellRules,
    Object? effective = _aiSettingsUnset,
    LocalStatusOverview? statusOverview,
    Object? selectedWorkspaceRoot = _aiSettingsUnset,
    String? workspaceSearchQuery,
    List<AiRecentWorkspace>? recentWorkspaces,
    bool? hasWorkspaceSirixConfig,
    bool? hasWorkspaceCodexConfig,
    bool clearError = false,
    bool clearNotice = false,
  }) {
    return AiSettingsState(
      scope: scope ?? this.scope,
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      discoveringProviderIds: discoveringProviderIds ?? this.discoveringProviderIds,
      authBusyProviderIds: authBusyProviderIds ?? this.authBusyProviderIds,
      openAiAuthStatuses: openAiAuthStatuses ?? this.openAiAuthStatuses,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      noticeMessage: clearNotice ? null : (noticeMessage ?? this.noticeMessage),
      selectedSection: selectedSection ?? this.selectedSection,
      config: config ?? this.config,
      globalConfig: identical(globalConfig, _aiSettingsUnset)
          ? this.globalConfig
          : globalConfig as SirixAiConfig?,
      shellRules: shellRules ?? this.shellRules,
      effective: identical(effective, _aiSettingsUnset)
          ? this.effective
          : effective as EffectiveSirixAiConfig?,
      statusOverview: statusOverview ?? this.statusOverview,
      selectedWorkspaceRoot: identical(selectedWorkspaceRoot, _aiSettingsUnset)
          ? this.selectedWorkspaceRoot
          : selectedWorkspaceRoot as String?,
      workspaceSearchQuery: workspaceSearchQuery ?? this.workspaceSearchQuery,
      recentWorkspaces: recentWorkspaces ?? this.recentWorkspaces,
      hasWorkspaceSirixConfig: hasWorkspaceSirixConfig ?? this.hasWorkspaceSirixConfig,
      hasWorkspaceCodexConfig: hasWorkspaceCodexConfig ?? this.hasWorkspaceCodexConfig,
    );
  }
}

CapabilityRulesConfigModel _mergeCapabilityRulesLikeServer(
  CapabilityRulesConfigModel base,
  CapabilityRulesConfigModel overlay,
) {
  return _isDefaultCapabilityRules(overlay)
      ? base
      : mergeCapabilityRules(base, overlay);
}

bool _isDefaultMcpGlobalConfig(McpGlobalConfigModel config) {
  return config.enabled == true &&
      config.allowStdio == true &&
      config.allowHttp == true;
}

bool _isDefaultCapabilityRules(CapabilityRulesConfigModel config) {
  return config.version == 1 &&
      config.mode == ApprovalMode.ask &&
      config.rules.isEmpty;
}

List<T> _mergeById<T>(
  List<T> base,
  List<T> overlay,
  String Function(T item) getId,
) {
  final merged = [...base];
  for (final item in overlay) {
    final itemId = getId(item);
    final index = merged.indexWhere((candidate) => getId(candidate) == itemId);
    if (index < 0) {
      merged.add(item);
    } else {
      merged[index] = item;
    }
  }
  return merged;
}
const _sceneWorkspaceDirName =
    String.fromEnvironment('SIRIX_SCENE', defaultValue: 'debug') == 'release'
    ? '.sirix'
    : '.sirix-debug';
