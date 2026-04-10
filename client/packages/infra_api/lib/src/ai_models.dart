import 'package:flutter/foundation.dart';

String _enumName(Object value) => value.toString().split('.').last;

enum ProviderKind {
  openAiCompatible,
  openAiResponses,
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
  askOnce,
  askEachTime,
  deny,
}

ProviderKind providerKindFromJson(String? raw) {
  return ProviderKind.values.firstWhere(
    (item) => _enumName(item) == raw,
    orElse: () => ProviderKind.openAiResponses,
  );
}

ModelKind modelKindFromJson(String? raw) {
  return ModelKind.values.firstWhere(
    (item) => _enumName(item) == raw,
    orElse: () => ModelKind.text,
  );
}

ApprovalMode approvalModeFromJson(String? raw) {
  return ApprovalMode.values.firstWhere(
    (item) => _enumName(item) == raw,
    orElse: () => ApprovalMode.allow,
  );
}

@immutable
class CliSettingsConfig {
  const CliSettingsConfig({
    this.supplementalSystemPrompt = '',
  });

  final String supplementalSystemPrompt;

  factory CliSettingsConfig.fromJson(Map<String, dynamic> json) {
    return CliSettingsConfig(
      supplementalSystemPrompt: json['supplemental_system_prompt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'supplemental_system_prompt': supplementalSystemPrompt,
    };
  }

  CliSettingsConfig copyWith({
    String? supplementalSystemPrompt,
  }) {
    return CliSettingsConfig(
      supplementalSystemPrompt: supplementalSystemPrompt ?? this.supplementalSystemPrompt,
    );
  }
}

@immutable
class AiModelConfig {
  const AiModelConfig({
    required this.id,
    required this.displayName,
    required this.modelKind,
    required this.contextWindow,
    this.supportsImages = false,
    this.enabled = true,
  });

  final String id;
  final String displayName;
  final ModelKind modelKind;
  final int contextWindow;
  final bool supportsImages;
  final bool enabled;

  factory AiModelConfig.fromJson(Map<String, dynamic> json) {
    return AiModelConfig(
      id: json['id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      modelKind: modelKindFromJson(json['model_kind'] as String?),
      contextWindow: (json['context_window'] as num?)?.toInt() ?? 0,
      supportsImages: json['supports_images'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'display_name': displayName,
      'model_kind': _enumName(modelKind),
      'context_window': contextWindow,
      'supports_images': supportsImages,
      'enabled': enabled,
    };
  }

  AiModelConfig copyWith({
    String? id,
    String? displayName,
    ModelKind? modelKind,
    int? contextWindow,
    bool? supportsImages,
    bool? enabled,
  }) {
    return AiModelConfig(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      modelKind: modelKind ?? this.modelKind,
      contextWindow: contextWindow ?? this.contextWindow,
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
      'kind': _enumName(kind),
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
      'approval_mode': _enumName(approvalMode),
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
class AgentCapabilityRuleModel {
  const AgentCapabilityRuleModel({
    required this.key,
    this.approvalMode = ApprovalMode.allow,
  });

  final String key;
  final ApprovalMode approvalMode;

  factory AgentCapabilityRuleModel.fromJson(Map<String, dynamic> json) {
    return AgentCapabilityRuleModel(
      key: json['key'] as String? ?? '',
      approvalMode: approvalModeFromJson(json['approval_mode'] as String?),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'approval_mode': _enumName(approvalMode),
    };
  }

  AgentCapabilityRuleModel copyWith({
    String? key,
    ApprovalMode? approvalMode,
  }) {
    return AgentCapabilityRuleModel(
      key: key ?? this.key,
      approvalMode: approvalMode ?? this.approvalMode,
    );
  }
}

@immutable
class AgentConfigModel {
  const AgentConfigModel({
    required this.id,
    required this.name,
    required this.providerId,
    required this.modelId,
    this.systemPrompt = '',
    this.builtinToolsEnabled = true,
    this.enabledSkillIds = const [],
    this.disabledSkillIds = const [],
    this.enabledMcpServerIds = const [],
    this.disabledMcpServerIds = const [],
    this.capabilityRules = const [],
    this.enabled = true,
  });

  final String id;
  final String name;
  final String providerId;
  final String modelId;
  final String systemPrompt;
  final bool builtinToolsEnabled;
  final List<String> enabledSkillIds;
  final List<String> disabledSkillIds;
  final List<String> enabledMcpServerIds;
  final List<String> disabledMcpServerIds;
  final List<AgentCapabilityRuleModel> capabilityRules;
  final bool enabled;

  factory AgentConfigModel.fromJson(Map<String, dynamic> json) {
    final rawRules = json['capability_rules'] as List<dynamic>? ?? const [];
    return AgentConfigModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      providerId: json['provider_id'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String? ?? '',
      builtinToolsEnabled: json['builtin_tools_enabled'] as bool? ?? true,
      enabledSkillIds: (json['enabled_skill_ids'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      disabledSkillIds: (json['disabled_skill_ids'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      enabledMcpServerIds:
          (json['enabled_mcp_server_ids'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(growable: false),
      disabledMcpServerIds:
          (json['disabled_mcp_server_ids'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(growable: false),
      capabilityRules: rawRules
          .whereType<Map<String, dynamic>>()
          .map(AgentCapabilityRuleModel.fromJson)
          .toList(growable: false),
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'provider_id': providerId,
      'model_id': modelId,
      'system_prompt': systemPrompt,
      'builtin_tools_enabled': builtinToolsEnabled,
      'enabled_skill_ids': enabledSkillIds,
      'disabled_skill_ids': disabledSkillIds,
      'enabled_mcp_server_ids': enabledMcpServerIds,
      'disabled_mcp_server_ids': disabledMcpServerIds,
      'capability_rules': capabilityRules.map((item) => item.toJson()).toList(growable: false),
      'enabled': enabled,
    };
  }

  AgentConfigModel copyWith({
    String? id,
    String? name,
    String? providerId,
    String? modelId,
    String? systemPrompt,
    bool? builtinToolsEnabled,
    List<String>? enabledSkillIds,
    List<String>? disabledSkillIds,
    List<String>? enabledMcpServerIds,
    List<String>? disabledMcpServerIds,
    List<AgentCapabilityRuleModel>? capabilityRules,
    bool? enabled,
  }) {
    return AgentConfigModel(
      id: id ?? this.id,
      name: name ?? this.name,
      providerId: providerId ?? this.providerId,
      modelId: modelId ?? this.modelId,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      builtinToolsEnabled: builtinToolsEnabled ?? this.builtinToolsEnabled,
      enabledSkillIds: enabledSkillIds ?? this.enabledSkillIds,
      disabledSkillIds: disabledSkillIds ?? this.disabledSkillIds,
      enabledMcpServerIds: enabledMcpServerIds ?? this.enabledMcpServerIds,
      disabledMcpServerIds: disabledMcpServerIds ?? this.disabledMcpServerIds,
      capabilityRules: capabilityRules ?? this.capabilityRules,
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
