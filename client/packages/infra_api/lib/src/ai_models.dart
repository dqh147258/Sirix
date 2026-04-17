import 'package:flutter/foundation.dart';

const Object _unset = Object();

enum ProviderKind {
  openAiCompatible,
  openAiResponses,
  openAiCodexOauth,
  openAiCodexApi,
  gemini,
  anthropic,
}

enum ModelKind {
  text,
  imageGeneration,
  asr,
  tts,
  embedding,
}

enum ApprovalMode {
  allow,
  ask,
  deny,
}

String _providerKindJson(ProviderKind value) {
  return switch (value) {
    ProviderKind.openAiCompatible => 'open_ai_compatible',
    ProviderKind.openAiResponses => 'open_ai_responses',
    ProviderKind.openAiCodexOauth => 'open_ai_codex_oauth',
    ProviderKind.openAiCodexApi => 'open_ai_codex_api',
    ProviderKind.gemini => 'gemini',
    ProviderKind.anthropic => 'anthropic',
  };
}

String _modelKindJson(ModelKind value) {
  return switch (value) {
    ModelKind.text => 'text',
    ModelKind.imageGeneration => 'image_generation',
    ModelKind.asr => 'asr',
    ModelKind.tts => 'tts',
    ModelKind.embedding => 'embedding',
  };
}

String _approvalModeJson(ApprovalMode value) {
  return switch (value) {
    ApprovalMode.allow => 'allow',
    ApprovalMode.ask => 'ask',
    ApprovalMode.deny => 'deny',
  };
}

ProviderKind providerKindFromJson(String? raw) {
  return switch (raw) {
    'open_ai_compatible' || 'openAiCompatible' => ProviderKind.openAiCompatible,
    'open_ai_responses' || 'openAiResponses' => ProviderKind.openAiResponses,
    'open_ai_codex_oauth' || 'openAiCodexOauth' => ProviderKind.openAiCodexOauth,
    'open_ai_codex_api' || 'openAiCodexApi' => ProviderKind.openAiCodexApi,
    'gemini' => ProviderKind.gemini,
    'anthropic' => ProviderKind.anthropic,
    _ => ProviderKind.openAiResponses,
  };
}

ModelKind modelKindFromJson(String? raw) {
  return switch (raw) {
    'text' => ModelKind.text,
    'image_generation' || 'imageGeneration' => ModelKind.imageGeneration,
    'asr' => ModelKind.asr,
    'tts' => ModelKind.tts,
    'embedding' => ModelKind.embedding,
    _ => ModelKind.text,
  };
}

ApprovalMode approvalModeFromJson(String? raw) {
  return switch (raw) {
    'allow' => ApprovalMode.allow,
    'ask' || 'ask_once' || 'askOnce' || 'ask_each_time' || 'askEachTime' => ApprovalMode.ask,
    'deny' => ApprovalMode.deny,
    _ => ApprovalMode.allow,
  };
}

/// Keep the client-side builtin tool catalog aligned with desktop-server so the
/// settings page can render picker options without requiring a second discovery
/// round-trip for static metadata.
const List<String> kBuiltinToolCatalog = [
  'shell',
  'shell_command',
  'exec_command',
  'write_stdin',
  'apply_patch',
  'update_plan',
  'request_user_input',
  'request_permissions',
  'view_image',
  'web_search',
  'image_generation',
  'code_mode',
  'js_repl',
  'js_repl_reset',
  'list_dir',
  'list_mcp_resources',
  'list_mcp_resource_templates',
  'read_mcp_resource',
  'spawn_agent',
  'send_message',
  'followup_task',
  'wait_agent',
  'close_agent',
  'list_agents',
];

@immutable
class CliSettingsConfig {
  const CliSettingsConfig({
    this.supplementalSystemPrompt = '',
    this.closeModelWithoutConfirmation = false,
  });

  final String supplementalSystemPrompt;
  final bool closeModelWithoutConfirmation;

  factory CliSettingsConfig.fromJson(Map<String, dynamic> json) {
    return CliSettingsConfig(
      supplementalSystemPrompt: json['supplemental_system_prompt'] as String? ?? '',
      closeModelWithoutConfirmation:
          json['close_model_without_confirmation'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'supplemental_system_prompt': supplementalSystemPrompt,
      'close_model_without_confirmation': closeModelWithoutConfirmation,
    };
  }

  CliSettingsConfig copyWith({
    String? supplementalSystemPrompt,
    bool? closeModelWithoutConfirmation,
  }) {
    return CliSettingsConfig(
      supplementalSystemPrompt: supplementalSystemPrompt ?? this.supplementalSystemPrompt,
      closeModelWithoutConfirmation:
          closeModelWithoutConfirmation ?? this.closeModelWithoutConfirmation,
    );
  }
}

@immutable
class AiModelConfig {
  const AiModelConfig({
    required this.id,
    required this.displayName,
    required this.modelKind,
    this.contextWindow,
    this.supportsImages = false,
    this.enabled = true,
  });

  final String id;
  final String displayName;
  final ModelKind modelKind;
  final int? contextWindow;
  final bool supportsImages;
  final bool enabled;

  factory AiModelConfig.fromJson(Map<String, dynamic> json) {
    return AiModelConfig(
      id: json['id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      modelKind: modelKindFromJson(json['model_kind'] as String?),
      contextWindow: (json['context_window'] as num?)?.toInt(),
      supportsImages: json['supports_images'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'display_name': displayName,
      'model_kind': _modelKindJson(modelKind),
      'context_window': contextWindow,
      'supports_images': supportsImages,
      'enabled': enabled,
    };
  }

  AiModelConfig copyWith({
    String? id,
    String? displayName,
    ModelKind? modelKind,
    Object? contextWindow = _unset,
    bool? supportsImages,
    bool? enabled,
  }) {
    return AiModelConfig(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      modelKind: modelKind ?? this.modelKind,
      contextWindow: identical(contextWindow, _unset) ? this.contextWindow : contextWindow as int?,
      supportsImages: supportsImages ?? this.supportsImages,
      enabled: enabled ?? this.enabled,
    );
  }
}

@immutable
class AiProviderConfig {
  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.kind,
    this.defaultContextWindow,
    this.baseUrl = '',
    this.apiKeyEnv = '',
    this.apiKey = '',
    this.headersJson = '{}',
    this.enabled = true,
    this.models = const [],
  });

  final String id;
  final String name;
  final ProviderKind kind;
  final int? defaultContextWindow;
  final String baseUrl;
  final String apiKeyEnv;
  final String apiKey;
  final String headersJson;
  final bool enabled;
  final List<AiModelConfig> models;

  factory AiProviderConfig.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'] as List<dynamic>? ?? const [];
    return AiProviderConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: providerKindFromJson(json['kind'] as String?),
      defaultContextWindow: (json['default_context_window'] as num?)?.toInt(),
      baseUrl: json['base_url'] as String? ?? '',
      apiKeyEnv: json['api_key_env'] as String? ?? '',
      apiKey: json['api_key'] as String? ?? '',
      headersJson: json['headers_json'] as String? ?? '{}',
      enabled: json['enabled'] as bool? ?? true,
      models: rawModels
          .whereType<Map<String, dynamic>>()
          .map(AiModelConfig.fromJson)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'kind': _providerKindJson(kind),
      'default_context_window': defaultContextWindow,
      'base_url': baseUrl,
      'api_key_env': apiKeyEnv,
      'api_key': apiKey,
      'headers_json': headersJson,
      'enabled': enabled,
      'models': models.map((item) => item.toJson()).toList(growable: false),
    };
  }

  AiProviderConfig copyWith({
    String? id,
    String? name,
    ProviderKind? kind,
    Object? defaultContextWindow = _unset,
    String? baseUrl,
    String? apiKeyEnv,
    String? apiKey,
    String? headersJson,
    bool? enabled,
    List<AiModelConfig>? models,
  }) {
    return AiProviderConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      defaultContextWindow: identical(defaultContextWindow, _unset)
          ? this.defaultContextWindow
          : defaultContextWindow as int?,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
      apiKey: apiKey ?? this.apiKey,
      headersJson: headersJson ?? this.headersJson,
      enabled: enabled ?? this.enabled,
      models: models ?? this.models,
    );
  }
}

@immutable
class OpenAiAuthStatus {
  const OpenAiAuthStatus({
    required this.providerId,
    this.authenticated = false,
    this.authMode,
    this.email,
    this.planType,
    this.accountId,
    this.loginInProgress = false,
  });

  final String providerId;
  final bool authenticated;
  final String? authMode;
  final String? email;
  final String? planType;
  final String? accountId;
  final bool loginInProgress;

  factory OpenAiAuthStatus.fromJson(Map<String, dynamic> json) {
    return OpenAiAuthStatus(
      providerId: json['provider_id'] as String? ?? '',
      authenticated: json['authenticated'] as bool? ?? false,
      authMode: json['auth_mode'] as String?,
      email: json['email'] as String?,
      planType: json['plan_type'] as String?,
      accountId: json['account_id'] as String?,
      loginInProgress: json['login_in_progress'] as bool? ?? false,
    );
  }
}

@immutable
class SkillConfigModel {
  const SkillConfigModel({
    required this.id,
    required this.name,
    required this.path,
    this.enabled = true,
    this.allowOutsideSandbox = false,
  });

  final String id;
  final String name;
  final String path;
  final bool enabled;
  final bool allowOutsideSandbox;

  factory SkillConfigModel.fromJson(Map<String, dynamic> json) {
    return SkillConfigModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      allowOutsideSandbox: json['allow_outside_sandbox'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'enabled': enabled,
      'allow_outside_sandbox': allowOutsideSandbox,
    };
  }

  SkillConfigModel copyWith({
    String? id,
    String? name,
    String? path,
    bool? enabled,
    bool? allowOutsideSandbox,
  }) {
    return SkillConfigModel(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      enabled: enabled ?? this.enabled,
      allowOutsideSandbox: allowOutsideSandbox ?? this.allowOutsideSandbox,
    );
  }
}

@immutable
class McpServerConfigModel {
  const McpServerConfigModel({
    required this.id,
    required this.name,
    this.enabled = true,
    this.approvalMode = ApprovalMode.allow,
    this.enabledTools = const [],
    this.disabledTools = const [],
    this.jsonConfig = '{}',
  });

  final String id;
  final String name;
  final bool enabled;
  final ApprovalMode approvalMode;
  final List<String> enabledTools;
  final List<String> disabledTools;
  final String jsonConfig;

  factory McpServerConfigModel.fromJson(Map<String, dynamic> json) {
    return McpServerConfigModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      approvalMode: approvalModeFromJson(json['approval_mode'] as String?),
      enabledTools: (json['enabled_tools'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      disabledTools: (json['disabled_tools'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      jsonConfig: json['json_config'] as String? ?? '{}',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'enabled': enabled,
      'approval_mode': _approvalModeJson(approvalMode),
      'enabled_tools': enabledTools,
      'disabled_tools': disabledTools,
      'json_config': jsonConfig,
    };
  }

  McpServerConfigModel copyWith({
    String? id,
    String? name,
    bool? enabled,
    ApprovalMode? approvalMode,
    List<String>? enabledTools,
    List<String>? disabledTools,
    String? jsonConfig,
  }) {
    return McpServerConfigModel(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      approvalMode: approvalMode ?? this.approvalMode,
      enabledTools: enabledTools ?? this.enabledTools,
      disabledTools: disabledTools ?? this.disabledTools,
      jsonConfig: jsonConfig ?? this.jsonConfig,
    );
  }
}

@immutable
class McpGlobalConfigModel {
  const McpGlobalConfigModel({
    this.enabled = true,
    this.allowStdio = true,
    this.allowHttp = true,
  });

  final bool enabled;
  final bool allowStdio;
  final bool allowHttp;

  factory McpGlobalConfigModel.fromJson(Map<String, dynamic> json) {
    return McpGlobalConfigModel(
      enabled: json['enabled'] as bool? ?? true,
      allowStdio: json['allow_stdio'] as bool? ?? true,
      allowHttp: json['allow_http'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'allow_stdio': allowStdio,
      'allow_http': allowHttp,
    };
  }

  McpGlobalConfigModel copyWith({
    bool? enabled,
    bool? allowStdio,
    bool? allowHttp,
  }) {
    return McpGlobalConfigModel(
      enabled: enabled ?? this.enabled,
      allowStdio: allowStdio ?? this.allowStdio,
      allowHttp: allowHttp ?? this.allowHttp,
    );
  }
}

@immutable
class ShellRulesConfigModel {
  const ShellRulesConfigModel({
    this.version = 1,
    this.mode = ApprovalMode.ask,
    this.allow = const [],
    this.deny = const ['rm -rf', 'sudo rm', 'mkfs'],
  });

  final int version;
  final ApprovalMode mode;
  final List<String> allow;
  final List<String> deny;

  factory ShellRulesConfigModel.fromJson(Map<String, dynamic> json) {
    return ShellRulesConfigModel(
      version: (json['version'] as num?)?.toInt() ?? 1,
      mode: approvalModeFromJson(json['mode'] as String?),
      allow: (json['allow'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      deny: (json['deny'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'mode': _approvalModeJson(mode),
      'allow': allow,
      'deny': deny,
    };
  }

  ShellRulesConfigModel copyWith({
    int? version,
    ApprovalMode? mode,
    List<String>? allow,
    List<String>? deny,
  }) {
    return ShellRulesConfigModel(
      version: version ?? this.version,
      mode: mode ?? this.mode,
      allow: allow ?? this.allow,
      deny: deny ?? this.deny,
    );
  }
}

@immutable
class AgentConfigModel {
  const AgentConfigModel({
    required this.id,
    required this.name,
    this.description = '',
    required this.providerId,
    required this.modelId,
    this.fallbackProviderId = '',
    this.fallbackModelId = '',
    this.systemPrompt = '',
    this.approvalMode = ApprovalMode.ask,
    this.shellRules = const ShellRulesConfigModel(),
    this.toolRules = const ShellRulesConfigModel(),
    this.builtinToolIds = kBuiltinToolCatalog,
    this.skillIds = const [],
    this.mcpServerIds = const [],
    this.subAgentIds = const [],
    this.enabled = true,
  });

  final String id;
  final String name;
  final String description;
  final String providerId;
  final String modelId;
  final String fallbackProviderId;
  final String fallbackModelId;
  final String systemPrompt;
  final ApprovalMode approvalMode;
  final ShellRulesConfigModel shellRules;
  final ShellRulesConfigModel toolRules;
  final List<String> builtinToolIds;
  final List<String> skillIds;
  final List<String> mcpServerIds;
  final List<String> subAgentIds;
  final bool enabled;

  factory AgentConfigModel.fromJson(Map<String, dynamic> json) {
    final builtinToolIds = (json['builtin_tool_ids'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final skillIds = (json['skill_ids'] as List<dynamic>? ??
            json['enabled_skill_ids'] as List<dynamic>? ??
            const [])
        .whereType<String>()
        .toList(growable: false);
    final mcpServerIds = (json['mcp_server_ids'] as List<dynamic>? ??
            json['enabled_mcp_server_ids'] as List<dynamic>? ??
            const [])
        .whereType<String>()
        .toList(growable: false);
    return AgentConfigModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      providerId: json['provider_id'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      fallbackProviderId: json['fallback_provider_id'] as String? ?? '',
      fallbackModelId: json['fallback_model_id'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String? ?? '',
      approvalMode: approvalModeFromJson(json['approval_mode'] as String?),
      shellRules: ShellRulesConfigModel.fromJson(
        (json['shell_rules'] as Map<Object?, Object?>? ?? const {}).cast<String, dynamic>(),
      ),
      toolRules: ShellRulesConfigModel.fromJson(
        (json['tool_rules'] as Map<Object?, Object?>? ?? const {}).cast<String, dynamic>(),
      ),
      builtinToolIds: builtinToolIds.isEmpty
          ? (json['builtin_tools_enabled'] as bool? ?? true)
              ? kBuiltinToolCatalog
              : const <String>[]
          : builtinToolIds,
      skillIds: skillIds,
      mcpServerIds: mcpServerIds,
      subAgentIds: (json['sub_agent_ids'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'provider_id': providerId,
      'model_id': modelId,
      'fallback_provider_id': fallbackProviderId,
      'fallback_model_id': fallbackModelId,
      'system_prompt': systemPrompt,
      'approval_mode': _approvalModeJson(approvalMode),
      'shell_rules': shellRules.toJson(),
      'tool_rules': toolRules.toJson(),
      'builtin_tool_ids': builtinToolIds,
      'skill_ids': skillIds,
      'mcp_server_ids': mcpServerIds,
      'sub_agent_ids': subAgentIds,
      'enabled': enabled,
    };
  }

  AgentConfigModel copyWith({
    String? id,
    String? name,
    String? description,
    String? providerId,
    String? modelId,
    String? fallbackProviderId,
    String? fallbackModelId,
    String? systemPrompt,
    ApprovalMode? approvalMode,
    ShellRulesConfigModel? shellRules,
    ShellRulesConfigModel? toolRules,
    List<String>? builtinToolIds,
    List<String>? skillIds,
    List<String>? mcpServerIds,
    List<String>? subAgentIds,
    bool? enabled,
  }) {
    return AgentConfigModel(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      providerId: providerId ?? this.providerId,
      modelId: modelId ?? this.modelId,
      fallbackProviderId: fallbackProviderId ?? this.fallbackProviderId,
      fallbackModelId: fallbackModelId ?? this.fallbackModelId,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      approvalMode: approvalMode ?? this.approvalMode,
      shellRules: shellRules ?? this.shellRules,
      toolRules: toolRules ?? this.toolRules,
      builtinToolIds: builtinToolIds ?? this.builtinToolIds,
      skillIds: skillIds ?? this.skillIds,
      mcpServerIds: mcpServerIds ?? this.mcpServerIds,
      subAgentIds: subAgentIds ?? this.subAgentIds,
      enabled: enabled ?? this.enabled,
    );
  }
}

@immutable
class SirixAiConfig {
  const SirixAiConfig({
    this.version = 1,
    this.cli = const CliSettingsConfig(),
    this.providers = const [],
    this.skills = const [],
    this.mcp = const McpGlobalConfigModel(),
    this.mcpServers = const [],
    this.agents = const [],
  });

  final int version;
  final CliSettingsConfig cli;
  final List<AiProviderConfig> providers;
  final List<SkillConfigModel> skills;
  final McpGlobalConfigModel mcp;
  final List<McpServerConfigModel> mcpServers;
  final List<AgentConfigModel> agents;

  factory SirixAiConfig.fromJson(Map<String, dynamic> json) {
    return SirixAiConfig(
      version: (json['version'] as num?)?.toInt() ?? 1,
      cli: CliSettingsConfig.fromJson(
        (json['cli'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
      providers: (json['providers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AiProviderConfig.fromJson)
          .toList(growable: false),
      skills: (json['skills'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SkillConfigModel.fromJson)
          .toList(growable: false),
      mcp: McpGlobalConfigModel.fromJson(
        (json['mcp'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
      mcpServers: (json['mcp_servers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(McpServerConfigModel.fromJson)
          .toList(growable: false),
      agents: (json['agents'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AgentConfigModel.fromJson)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'cli': cli.toJson(),
      'providers': providers.map((item) => item.toJson()).toList(growable: false),
      'skills': skills.map((item) => item.toJson()).toList(growable: false),
      'mcp': mcp.toJson(),
      'mcp_servers': mcpServers.map((item) => item.toJson()).toList(growable: false),
      'agents': agents.map((item) => item.toJson()).toList(growable: false),
    };
  }

  SirixAiConfig copyWith({
    int? version,
    CliSettingsConfig? cli,
    List<AiProviderConfig>? providers,
    List<SkillConfigModel>? skills,
    McpGlobalConfigModel? mcp,
    List<McpServerConfigModel>? mcpServers,
    List<AgentConfigModel>? agents,
  }) {
    return SirixAiConfig(
      version: version ?? this.version,
      cli: cli ?? this.cli,
      providers: providers ?? this.providers,
      skills: skills ?? this.skills,
      mcp: mcp ?? this.mcp,
      mcpServers: mcpServers ?? this.mcpServers,
      agents: agents ?? this.agents,
    );
  }
}

@immutable
class EffectiveSirixAiConfig {
  const EffectiveSirixAiConfig({
    required this.config,
    this.workspacePath,
    this.workspaceSource,
  });

  final SirixAiConfig config;
  final String? workspacePath;
  final String? workspaceSource;

  factory EffectiveSirixAiConfig.fromJson(Map<String, dynamic> json) {
    return EffectiveSirixAiConfig(
      config: SirixAiConfig.fromJson(
        (json['config'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
      workspacePath: json['workspace_path'] as String?,
      workspaceSource: json['workspace_source'] as String?,
    );
  }
}
