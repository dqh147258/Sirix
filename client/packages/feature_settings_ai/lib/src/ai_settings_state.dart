import 'package:flutter/foundation.dart';

import 'package:infra_api/infra_api.dart';

enum AiSettingsSection {
  cli,
  providers,
  skills,
  mcp,
  agents,
  shellRules,
}

@immutable
class AiSettingsState {
  const AiSettingsState({
    this.loading = false,
    this.saving = false,
    this.discoveringProviderIds = const [],
    this.errorMessage,
    this.noticeMessage,
    this.selectedSection = AiSettingsSection.cli,
    this.config = const SirixAiConfig(),
    this.shellRules = const ShellRulesConfigModel(),
    this.effective,
  });

  final bool loading;
  final bool saving;
  final List<String> discoveringProviderIds;
  final String? errorMessage;
  final String? noticeMessage;
  final AiSettingsSection selectedSection;
  final SirixAiConfig config;
  final ShellRulesConfigModel shellRules;
  final EffectiveSirixAiConfig? effective;

  AiSettingsState copyWith({
    bool? loading,
    bool? saving,
    List<String>? discoveringProviderIds,
    String? errorMessage,
    String? noticeMessage,
    AiSettingsSection? selectedSection,
    SirixAiConfig? config,
    ShellRulesConfigModel? shellRules,
    EffectiveSirixAiConfig? effective,
    bool clearError = false,
    bool clearNotice = false,
  }) {
    return AiSettingsState(
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      discoveringProviderIds: discoveringProviderIds ?? this.discoveringProviderIds,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      noticeMessage: clearNotice ? null : (noticeMessage ?? this.noticeMessage),
      selectedSection: selectedSection ?? this.selectedSection,
      config: config ?? this.config,
      shellRules: shellRules ?? this.shellRules,
      effective: effective ?? this.effective,
    );
  }
}
