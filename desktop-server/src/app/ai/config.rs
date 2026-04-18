use std::{
    collections::{BTreeMap, HashMap, HashSet},
    env, fs,
    path::{Path, PathBuf},
    sync::LazyLock,
};

use anyhow::Context;
use codex_core::build_responses_request_preview;
use codex_core::config::Config;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use toml::Value as TomlValue;
use uuid::Uuid;

const DEFAULT_AGENT_ID: &str = "codex";
const LEGACY_DEFAULT_AGENT_ID: &str = "default-agent";
const DEFAULT_AGENT_NAME: &str = "Codex";
const DEFAULT_AGENT_DESCRIPTION: &str =
    "Built-in Codex agent with the standard Codex system prompt.";
const DEFAULT_PROVIDER_ID: &str = "openai";
const DEFAULT_MODEL_ID: &str = "gpt-5";
const SIRIX_SESSION_PROXY_PROVIDER_ID: &str = "sirix-session-proxy";
const SIRIX_AGENT_ROLES_DIR: &str = "agent-roles";
pub const SIRIX_AGENT_RUNTIME_FILE_NAME: &str = "sirix-agent-runtime.json";
pub const SIRIX_CONFIG_OVERRIDES_FILE_NAME: &str = "sirix-config-overrides.json";
pub const SIRIX_EXEC_POLICY_RULES_DIR: &str = "rules";
pub const SIRIX_EXEC_POLICY_RULES_FILE: &str = "default.rules";
pub const SIRIX_CONFIG_OVERRIDES_PATH_ENV: &str = "SIRIX_CONFIG_OVERRIDES_PATH";
pub const SIRIX_EXEC_POLICY_PATH_ENV: &str = "SIRIX_EXEC_POLICY_PATH";
pub const SIRIX_AGENT_RUNTIME_PATH_ENV: &str = "SIRIX_AGENT_RUNTIME_PATH";
const SIRIX_SHARED_CODEX_HOME_DIR_NAME: &str = "codex-home";
const SIRIX_OLD_SHARED_CODEX_HOME_DIR_NAME: &str = "shared-codex-home";
const SIRIX_SHARED_STORAGE_MIGRATION_SENTINEL: &str = ".legacy-session-storage-migrated-v2";
const SIRIX_SESSIONS_SUBDIR: &str = "sessions";
const SIRIX_ARCHIVED_SESSIONS_SUBDIR: &str = "archived_sessions";
const SIRIX_SESSION_INDEX_FILE_NAME: &str = "session_index.jsonl";
static PROMPT_PREVIEW_RUNTIME_ENV_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    OpenAiCompatible,
    OpenAiResponses,
    OpenAiCodexOauth,
    OpenAiCodexApi,
    Gemini,
    Anthropic,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModelKind {
    Text,
    ImageGeneration,
    Asr,
    Tts,
    Embedding,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalMode {
    Allow,
    #[serde(
        alias = "ask_once",
        alias = "askOnce",
        alias = "ask_each_time",
        alias = "askEachTime"
    )]
    Ask,
    Deny,
}

impl Default for ApprovalMode {
    fn default() -> Self {
        Self::Allow
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CliSettings {
    #[serde(default)]
    pub supplemental_system_prompt: String,
    #[serde(default)]
    pub close_model_without_confirmation: bool,
}

impl Default for CliSettings {
    fn default() -> Self {
        Self {
            supplemental_system_prompt: String::new(),
            close_model_without_confirmation: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelConfig {
    pub id: String,
    pub display_name: String,
    pub model_kind: ModelKind,
    #[serde(default)]
    pub context_window: Option<u32>,
    #[serde(default)]
    pub supports_images: bool,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProviderConfig {
    pub id: String,
    pub name: String,
    pub kind: ProviderKind,
    #[serde(default)]
    pub default_context_window: Option<u32>,
    #[serde(default)]
    pub base_url: String,
    #[serde(default)]
    pub api_key_env: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default)]
    pub headers_json: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub models: Vec<ModelConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SkillConfig {
    pub id: String,
    pub name: String,
    pub path: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub allow_outside_sandbox: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct McpServerConfig {
    pub id: String,
    pub name: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub approval_mode: ApprovalMode,
    #[serde(default)]
    pub enabled_tools: Vec<String>,
    #[serde(default)]
    pub disabled_tools: Vec<String>,
    #[serde(default)]
    pub json_config: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct McpGlobalConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_true")]
    pub allow_stdio: bool,
    #[serde(default = "default_true")]
    pub allow_http: bool,
}

impl Default for McpGlobalConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            allow_stdio: true,
            allow_http: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AgentCapabilityRule {
    pub key: String,
    #[serde(default)]
    pub approval_mode: ApprovalMode,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ShellRulesConfig {
    #[serde(default = "default_shell_rules_version")]
    pub version: u32,
    #[serde(default = "default_shell_rules_mode")]
    pub mode: ApprovalMode,
    #[serde(default)]
    pub allow: Vec<String>,
    #[serde(default)]
    pub deny: Vec<String>,
}

impl Default for ShellRulesConfig {
    fn default() -> Self {
        Self {
            version: default_shell_rules_version(),
            mode: default_shell_rules_mode(),
            allow: Vec::new(),
            deny: default_shell_rules_deny_list(),
        }
    }
}

/// Tool permissions currently use the same `mode / allow / deny` envelope as
/// shell rules, but they are evaluated against tool capability keys (for
/// example `builtin.apply_patch` or `mcp.docs.search`) instead of shell
/// command prefixes.
pub type ToolRulesConfig = ShellRulesConfig;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionAgentRuntimeConfig {
    pub agent_id: String,
    #[serde(default)]
    pub shell_mode: ApprovalMode,
    #[serde(default)]
    pub builtin_tool_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AgentConfig {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub provider_id: String,
    pub model_id: String,
    #[serde(default)]
    pub fallback_provider_id: String,
    #[serde(default)]
    pub fallback_model_id: String,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default)]
    pub approval_mode: ApprovalMode,
    #[serde(default)]
    pub shell_rules: ShellRulesConfig,
    #[serde(default)]
    pub tool_rules: ToolRulesConfig,
    #[serde(default)]
    pub builtin_tool_ids: Vec<String>,
    #[serde(default)]
    pub skill_ids: Vec<String>,
    #[serde(default)]
    pub mcp_server_ids: Vec<String>,
    #[serde(default)]
    pub sub_agent_ids: Vec<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, skip_serializing)]
    legacy_builtin_tools_enabled: Option<bool>,
    #[serde(default, skip_serializing)]
    legacy_enabled_skill_ids: Vec<String>,
    #[serde(default, skip_serializing)]
    legacy_disabled_skill_ids: Vec<String>,
    #[serde(default, skip_serializing)]
    legacy_enabled_mcp_server_ids: Vec<String>,
    #[serde(default, skip_serializing)]
    legacy_disabled_mcp_server_ids: Vec<String>,
    #[serde(default, skip_serializing)]
    legacy_capability_rules: Vec<AgentCapabilityRule>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SirixConfig {
    #[serde(default = "default_config_version")]
    pub version: u32,
    #[serde(default)]
    pub cli: CliSettings,
    #[serde(default)]
    pub providers: Vec<ProviderConfig>,
    #[serde(default)]
    pub skills: Vec<SkillConfig>,
    #[serde(default)]
    pub mcp: McpGlobalConfig,
    #[serde(default)]
    pub mcp_servers: Vec<McpServerConfig>,
    #[serde(default)]
    pub agents: Vec<AgentConfig>,
}

impl Default for SirixConfig {
    fn default() -> Self {
        Self {
            version: default_config_version(),
            cli: CliSettings::default(),
            providers: vec![ProviderConfig {
                id: DEFAULT_PROVIDER_ID.to_string(),
                name: "OpenAI".to_string(),
                kind: ProviderKind::OpenAiResponses,
                default_context_window: Some(200_000),
                base_url: "https://api.openai.com/v1".to_string(),
                api_key_env: "OPENAI_API_KEY".to_string(),
                api_key: String::new(),
                headers_json: "{}".to_string(),
                enabled: true,
                models: vec![ModelConfig {
                    id: DEFAULT_MODEL_ID.to_string(),
                    display_name: "GPT-5".to_string(),
                    model_kind: ModelKind::Text,
                    context_window: None,
                    supports_images: true,
                    enabled: true,
                }],
            }],
            skills: Vec::new(),
            mcp: McpGlobalConfig::default(),
            mcp_servers: Vec::new(),
            agents: vec![AgentConfig {
                id: DEFAULT_AGENT_ID.to_string(),
                name: DEFAULT_AGENT_NAME.to_string(),
                description: DEFAULT_AGENT_DESCRIPTION.to_string(),
                provider_id: DEFAULT_PROVIDER_ID.to_string(),
                model_id: DEFAULT_MODEL_ID.to_string(),
                fallback_provider_id: String::new(),
                fallback_model_id: String::new(),
                system_prompt: String::new(),
                approval_mode: ApprovalMode::Ask,
                shell_rules: ShellRulesConfig::default(),
                tool_rules: ToolRulesConfig::default(),
                builtin_tool_ids: default_builtin_tool_ids(),
                skill_ids: Vec::new(),
                mcp_server_ids: Vec::new(),
                sub_agent_ids: Vec::new(),
                enabled: true,
                legacy_builtin_tools_enabled: None,
                legacy_enabled_skill_ids: Vec::new(),
                legacy_disabled_skill_ids: Vec::new(),
                legacy_enabled_mcp_server_ids: Vec::new(),
                legacy_disabled_mcp_server_ids: Vec::new(),
                legacy_capability_rules: vec![AgentCapabilityRule {
                    key: "builtin.shell".to_string(),
                    approval_mode: ApprovalMode::Ask,
                }],
            }],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EffectiveSirixConfig {
    pub config: SirixConfig,
    pub workspace_path: Option<String>,
    pub workspace_source: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiLaunchConfig {
    pub effective_config: SirixConfig,
    pub agent: AgentConfig,
    pub provider: ProviderConfig,
    pub model: ModelConfig,
    pub session_providers: Vec<ProviderConfig>,
    pub codex_home: PathBuf,
    pub session_storage_dir: PathBuf,
    pub workspace_root: PathBuf,
    pub workspace_source: Option<PathBuf>,
}

pub struct SirixConfigStore {
    sirix_home: PathBuf,
    config_path: PathBuf,
}

impl SirixConfigStore {
    pub fn new() -> anyhow::Result<Self> {
        let sirix_home = sirix_home_dir()?;
        let config_path = sirix_home.join("config.toml");
        let store = Self {
            sirix_home,
            config_path,
        };
        store.ensure_layout()?;
        Ok(store)
    }

    pub fn sirix_home(&self) -> &Path {
        self.sirix_home.as_path()
    }

    pub fn config_path(&self) -> &Path {
        self.config_path.as_path()
    }

    pub fn provider_openai_auth_home(&self, provider_id: &str) -> PathBuf {
        self.sirix_home
            .join("runtime")
            .join("openai-auth")
            .join(provider_id)
    }

    pub fn load_global(&self) -> anyhow::Result<SirixConfig> {
        if !self.config_path.exists() {
            let default_config = SirixConfig::default();
            self.save_global(&default_config)?;
            return Ok(default_config);
        }

        let raw = fs::read_to_string(&self.config_path)
            .with_context(|| format!("failed to read {}", self.config_path.display()))?;
        parse_config_with_compat(&raw, &self.config_path)
    }

    pub fn save_global(&self, config: &SirixConfig) -> anyhow::Result<()> {
        let mut normalized = config.clone();
        normalize_sirix_config(&mut normalized);
        fs::create_dir_all(&self.sirix_home)
            .with_context(|| format!("failed to create {}", self.sirix_home.display()))?;
        let serialized =
            toml::to_string_pretty(&normalized).context("failed to serialize sirix config")?;
        fs::write(&self.config_path, serialized)
            .with_context(|| format!("failed to write {}", self.config_path.display()))?;
        Ok(())
    }

    pub fn global_shell_rules_path(&self) -> PathBuf {
        self.sirix_home.join("shell-rules.json")
    }

    pub fn global_tool_rules_path(&self) -> PathBuf {
        self.sirix_home.join("tool-rules.json")
    }

    pub fn workspace_shell_rules_path(&self, cwd: &Path) -> PathBuf {
        cwd.join(".sirix").join("shell-rules.json")
    }

    pub fn workspace_tool_rules_path(&self, cwd: &Path) -> PathBuf {
        cwd.join(".sirix").join("tool-rules.json")
    }

    fn shared_codex_home(&self) -> PathBuf {
        self.sirix_home.join(SIRIX_SHARED_CODEX_HOME_DIR_NAME)
    }

    fn shared_codex_config_path(&self) -> PathBuf {
        self.shared_codex_home().join("config.toml")
    }

    fn old_shared_codex_home(&self) -> PathBuf {
        self.sirix_home
            .join("runtime")
            .join(SIRIX_OLD_SHARED_CODEX_HOME_DIR_NAME)
    }

    pub fn load_global_shell_rules(&self) -> anyhow::Result<ShellRulesConfig> {
        self.load_shell_rules_from_path(&self.global_shell_rules_path())
    }

    pub fn save_global_shell_rules(&self, rules: &ShellRulesConfig) -> anyhow::Result<()> {
        self.save_shell_rules_to_path(&self.global_shell_rules_path(), rules)
    }

    pub fn load_global_tool_rules(&self) -> anyhow::Result<ToolRulesConfig> {
        self.load_rules_from_path(&self.global_tool_rules_path())
    }

    pub fn save_global_tool_rules(&self, rules: &ToolRulesConfig) -> anyhow::Result<()> {
        self.save_rules_to_path(&self.global_tool_rules_path(), rules)
    }

    pub fn load_workspace_shell_rules(
        &self,
        cwd: &Path,
    ) -> anyhow::Result<Option<ShellRulesConfig>> {
        let path = self.workspace_shell_rules_path(cwd);
        if !path.is_file() {
            return Ok(None);
        }
        self.load_shell_rules_from_path(&path).map(Some)
    }

    pub fn load_workspace_tool_rules(&self, cwd: &Path) -> anyhow::Result<Option<ToolRulesConfig>> {
        let path = self.workspace_tool_rules_path(cwd);
        if !path.is_file() {
            return Ok(None);
        }
        self.load_rules_from_path(&path).map(Some)
    }

    pub fn save_workspace_shell_rules(
        &self,
        cwd: &Path,
        rules: &ShellRulesConfig,
    ) -> anyhow::Result<()> {
        self.save_shell_rules_to_path(&self.workspace_shell_rules_path(cwd), rules)
    }

    pub fn save_workspace_tool_rules(
        &self,
        cwd: &Path,
        rules: &ToolRulesConfig,
    ) -> anyhow::Result<()> {
        self.save_rules_to_path(&self.workspace_tool_rules_path(cwd), rules)
    }

    pub fn effective_shell_rules(&self, cwd: &Path) -> anyhow::Result<ShellRulesConfig> {
        let global = self.load_global_shell_rules()?;
        let Some(workspace) = self.load_workspace_shell_rules(cwd)? else {
            return Ok(global);
        };
        Ok(merge_shell_rules(global, workspace))
    }

    pub fn effective_tool_rules(&self, cwd: &Path) -> anyhow::Result<ToolRulesConfig> {
        let global = self.load_global_tool_rules()?;
        let Some(workspace) = self.load_workspace_tool_rules(cwd)? else {
            return Ok(global);
        };
        Ok(merge_shell_rules(global, workspace))
    }

    pub fn build_session_agent_runtime(
        &self,
        cwd: &Path,
        agent: &AgentConfig,
        session_shell_rules: &ShellRulesConfig,
    ) -> anyhow::Result<SessionAgentRuntimeConfig> {
        let effective_shell_rules =
            self.effective_shell_rules_for_agent(cwd, agent, session_shell_rules)?;
        let shell_mode = match agent.approval_mode {
            ApprovalMode::Allow => ApprovalMode::Allow,
            ApprovalMode::Deny => ApprovalMode::Deny,
            ApprovalMode::Ask => effective_shell_rules.mode,
        };
        Ok(SessionAgentRuntimeConfig {
            agent_id: agent.id.clone(),
            shell_mode,
            builtin_tool_ids: agent.builtin_tool_ids.clone(),
        })
    }

    pub fn write_session_agent_runtime_file(
        &self,
        session_storage_dir: &Path,
        runtime: &SessionAgentRuntimeConfig,
    ) -> anyhow::Result<()> {
        fs::create_dir_all(session_storage_dir)
            .with_context(|| format!("failed to create {}", session_storage_dir.display()))?;
        let path = session_storage_dir.join(SIRIX_AGENT_RUNTIME_FILE_NAME);
        let serialized = serde_json::to_string_pretty(runtime)
            .context("failed to serialize session agent runtime")?;
        fs::write(&path, serialized).with_context(|| format!("failed to write {}", path.display()))
    }

    pub fn write_session_config_overrides_file(
        &self,
        session_storage_dir: &Path,
        overrides: &[String],
    ) -> anyhow::Result<PathBuf> {
        fs::create_dir_all(session_storage_dir)
            .with_context(|| format!("failed to create {}", session_storage_dir.display()))?;
        let path = session_storage_dir.join(SIRIX_CONFIG_OVERRIDES_FILE_NAME);
        let serialized = serde_json::to_string_pretty(overrides)
            .context("failed to serialize session config overrides")?;
        fs::write(&path, serialized)
            .with_context(|| format!("failed to write {}", path.display()))?;
        Ok(path)
    }

    pub fn write_session_exec_policy_file(
        &self,
        session_storage_dir: &Path,
        cwd: &Path,
        agent: &AgentConfig,
        session_shell_rules: &ShellRulesConfig,
    ) -> anyhow::Result<PathBuf> {
        let effective_shell_rules =
            self.effective_shell_rules_for_agent(cwd, agent, session_shell_rules)?;
        let rules_dir = session_storage_dir.join(SIRIX_EXEC_POLICY_RULES_DIR);
        fs::create_dir_all(&rules_dir)
            .with_context(|| format!("failed to create {}", rules_dir.display()))?;
        let path = rules_dir.join(SIRIX_EXEC_POLICY_RULES_FILE);
        let mut lines = Vec::<String>::new();
        for prefix in &effective_shell_rules.allow {
            if let Some(line) = render_exec_policy_prefix_rule(prefix, "allow", None) {
                lines.push(line);
            }
        }
        for prefix in &effective_shell_rules.deny {
            if let Some(line) = render_exec_policy_prefix_rule(
                prefix,
                "forbidden",
                Some("Blocked by Sirix shell rules."),
            ) {
                lines.push(line);
            }
        }
        let body = if lines.is_empty() {
            String::new()
        } else {
            format!("{}\n", lines.join("\n"))
        };
        fs::write(&path, body).with_context(|| format!("failed to write {}", path.display()))?;
        Ok(path)
    }

    pub fn effective_shell_rules_for_agent(
        &self,
        cwd: &Path,
        agent: &AgentConfig,
        session_shell_rules: &ShellRulesConfig,
    ) -> anyhow::Result<ShellRulesConfig> {
        // Shell rule precedence is Global -> Agent -> Workspace -> Session.
        // The workspace layer remains later than Agent so a concrete project can
        // still override a reusable profile when the two disagree.
        let global_rules = self.load_global_shell_rules()?;
        let agent_rules = merge_shell_rule_prefixes(global_rules, agent.shell_rules.clone());
        let workspace_rules = match self.load_workspace_shell_rules(cwd)? {
            Some(workspace_rules) => merge_shell_rules(agent_rules, workspace_rules),
            None => agent_rules,
        };
        Ok(merge_shell_rule_prefixes(
            workspace_rules,
            session_shell_rules.clone(),
        ))
    }

    pub fn effective_tool_rules_for_agent(
        &self,
        cwd: &Path,
        agent: &AgentConfig,
    ) -> anyhow::Result<ToolRulesConfig> {
        // Tool rules follow the requested precedence Global -> Agent -> Workspace.
        // Session-scope decisions are intentionally excluded here because the
        // approval registry handles them as volatile per-session overrides.
        let global_rules = self.load_global_tool_rules()?;
        let agent_rules = merge_shell_rule_prefixes(global_rules, agent.tool_rules.clone());
        Ok(match self.load_workspace_tool_rules(cwd)? {
            Some(workspace_rules) => merge_shell_rules(agent_rules, workspace_rules),
            None => agent_rules,
        })
    }

    pub fn effective_for_workspace(
        &self,
        cwd: Option<&str>,
    ) -> anyhow::Result<EffectiveSirixConfig> {
        let global = self.load_global()?;
        let Some(cwd) = cwd.filter(|value| !value.trim().is_empty()) else {
            return Ok(EffectiveSirixConfig {
                config: global,
                workspace_path: None,
                workspace_source: None,
            });
        };

        let workspace_dir = PathBuf::from(cwd);
        if !workspace_dir.is_dir() {
            return Ok(EffectiveSirixConfig {
                config: global,
                workspace_path: None,
                workspace_source: None,
            });
        }

        let sirix_workspace = workspace_dir.join(".sirix").join("config.toml");
        if sirix_workspace.is_file() {
            let raw = fs::read_to_string(&sirix_workspace)
                .with_context(|| format!("failed to read {}", sirix_workspace.display()))?;
            let workspace = parse_config_with_compat(&raw, &sirix_workspace)?;
            let workspace_cli_close_override =
                extract_cli_close_confirmation_override(&raw, &sirix_workspace)?;
            let mut merged = merge_sirix_config(global, workspace);
            // `CliSettings` keeps this toggle as a concrete `bool`, so regular deserialization
            // cannot tell whether the workspace omitted the field or explicitly set it to
            // `false`. Inspect the raw workspace TOML and only override the merged value when
            // the workspace file declared the toggle, so a workspace-level `false` can still
            // disable a global `true`.
            if let Some(close_without_confirmation) = workspace_cli_close_override {
                merged.cli.close_model_without_confirmation = close_without_confirmation;
            }
            return Ok(EffectiveSirixConfig {
                config: merged,
                workspace_path: Some(workspace_dir.display().to_string()),
                workspace_source: Some(sirix_workspace.display().to_string()),
            });
        }

        let codex_workspace = workspace_dir.join(".codex").join("config.toml");
        if codex_workspace.is_file() {
            return Ok(EffectiveSirixConfig {
                config: global,
                workspace_path: Some(workspace_dir.display().to_string()),
                workspace_source: Some(codex_workspace.display().to_string()),
            });
        }

        Ok(EffectiveSirixConfig {
            config: global,
            workspace_path: Some(workspace_dir.display().to_string()),
            workspace_source: None,
        })
    }

    pub fn build_launch_config(
        &self,
        cwd: &Path,
        agent_id: Option<&str>,
        session_id: Uuid,
    ) -> anyhow::Result<AiLaunchConfig> {
        let effective = self.effective_for_workspace(cwd.to_str())?;
        let config = effective.config;
        let agent = resolve_agent(&config, agent_id)?;
        let session_providers = config
            .providers
            .iter()
            .filter(|item| item.enabled)
            .cloned()
            .collect::<Vec<_>>();
        let provider = config
            .providers
            .iter()
            .find(|item| item.id == agent.provider_id && item.enabled)
            .cloned()
            .with_context(|| {
                format!(
                    "provider {} not found for agent {}",
                    agent.provider_id, agent.id
                )
            })?;
        let model = provider
            .models
            .iter()
            .find(|item| item.id == agent.model_id && item.enabled)
            .cloned()
            .with_context(|| {
                format!("model {} not found for agent {}", agent.model_id, agent.id)
            })?;
        let session_storage_dir = self
            .sirix_home
            .join("runtime")
            .join("sessions")
            .join(session_id.to_string());
        let codex_home = self.shared_codex_home();

        Ok(AiLaunchConfig {
            effective_config: config,
            agent,
            provider,
            model,
            session_providers,
            codex_home,
            session_storage_dir,
            workspace_root: cwd.to_path_buf(),
            workspace_source: effective.workspace_source.map(PathBuf::from),
        })
    }

    pub fn build_codex_cli_overrides(
        &self,
        launch: &AiLaunchConfig,
        cwd: &Path,
        local_ws_port: u16,
        ai_session_id: Uuid,
    ) -> anyhow::Result<Vec<String>> {
        self.ensure_shared_codex_home_layout()?;
        let config_value = build_codex_bridge_toml(
            launch.effective_config.clone(),
            launch,
            cwd,
            local_ws_port,
            ai_session_id,
        )?;
        render_cli_overrides(&config_value)
    }

    pub fn install_bin_shims(&self, current_exe: &Path) -> anyhow::Result<()> {
        let bin_dir = self.sirix_home.join("bin");
        fs::create_dir_all(&bin_dir)
            .with_context(|| format!("failed to create {}", bin_dir.display()))?;

        let sibling_dir = current_exe
            .parent()
            .context("desktop-server executable has no parent dir")?;
        let sirix_binary_name = if cfg!(windows) { "sirix.exe" } else { "sirix" };
        let sirix_binary = sibling_dir.join(sirix_binary_name);
        if !sirix_binary.exists() {
            return Ok(());
        }

        install_bin_shim(&sirix_binary, &bin_dir.join(sirix_binary_name))?;

        let sirix_terminal_binary_name = if cfg!(windows) {
            "sirix-terminal.exe"
        } else {
            "sirix-terminal"
        };
        let sirix_terminal_binary = sibling_dir.join(sirix_terminal_binary_name);
        if sirix_terminal_binary.exists() {
            install_bin_shim(
                &sirix_terminal_binary,
                &bin_dir.join(sirix_terminal_binary_name),
            )?;
        }

        let runtime_binary_name = if cfg!(windows) {
            "sirix-runtime.exe"
        } else {
            "sirix-runtime"
        };
        let runtime_binary = sibling_dir.join(runtime_binary_name);
        if runtime_binary.exists() {
            install_bin_shim(&runtime_binary, &bin_dir.join(runtime_binary_name))?;
            return Ok(());
        }

        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        for profile in ["debug", "release"] {
            let candidate = manifest_dir
                .join("..")
                .join("third_party")
                .join("codex-rs")
                .join("target")
                .join(profile)
                .join(runtime_binary_name);
            if candidate.exists() {
                install_bin_shim(&candidate, &bin_dir.join(runtime_binary_name))?;
                break;
            }
        }

        Ok(())
    }

    fn ensure_layout(&self) -> anyhow::Result<()> {
        migrate_legacy_codex_home(&self.sirix_home)?;
        fs::create_dir_all(self.sirix_home.join("runtime").join("sessions"))
            .with_context(|| format!("failed to create {}", self.sirix_home.display()))?;
        fs::create_dir_all(self.sirix_home.join("skills"))
            .with_context(|| format!("failed to create {}", self.sirix_home.display()))?;
        fs::create_dir_all(self.sirix_home.join("secrets"))
            .with_context(|| format!("failed to create {}", self.sirix_home.display()))?;
        self.ensure_shared_codex_home_layout()?;
        self.migrate_legacy_session_storage()?;
        Ok(())
    }

    fn ensure_shared_codex_home_layout(&self) -> anyhow::Result<()> {
        let shared_codex_home = self.shared_codex_home();
        fs::create_dir_all(shared_codex_home.join(SIRIX_SESSIONS_SUBDIR))
            .with_context(|| format!("failed to create {}", shared_codex_home.display()))?;
        fs::create_dir_all(shared_codex_home.join(SIRIX_ARCHIVED_SESSIONS_SUBDIR))
            .with_context(|| format!("failed to create {}", shared_codex_home.display()))?;
        let session_index_path = shared_codex_home.join(SIRIX_SESSION_INDEX_FILE_NAME);
        if !session_index_path.exists() {
            fs::write(&session_index_path, "").with_context(|| {
                format!("failed to initialize {}", session_index_path.display())
            })?;
        }
        Ok(())
    }

    fn migrate_legacy_session_storage(&self) -> anyhow::Result<()> {
        let shared_codex_home = self.shared_codex_home();
        let migration_sentinel = shared_codex_home.join(SIRIX_SHARED_STORAGE_MIGRATION_SENTINEL);
        if migration_sentinel.exists() {
            return Ok(());
        }

        self.merge_legacy_codex_home(self.old_shared_codex_home().as_path())?;

        let sessions_root = self.sirix_home.join("runtime").join("sessions");
        if sessions_root.is_dir() {
            for entry in fs::read_dir(&sessions_root)
                .with_context(|| format!("failed to read {}", sessions_root.display()))?
            {
                let entry = entry?;
                let legacy_codex_home = entry.path().join("codex-home");
                if !legacy_codex_home.is_dir() {
                    continue;
                }
                self.merge_legacy_codex_home(&legacy_codex_home)?;
            }
        }

        fs::write(&migration_sentinel, "ok\n")
            .with_context(|| format!("failed to write {}", migration_sentinel.display()))?;
        Ok(())
    }

    fn merge_legacy_codex_home(&self, legacy_codex_home: &Path) -> anyhow::Result<()> {
        if !legacy_codex_home.is_dir() {
            return Ok(());
        }

        let shared_codex_home = self.shared_codex_home();
        for dir_name in [SIRIX_SESSIONS_SUBDIR, SIRIX_ARCHIVED_SESSIONS_SUBDIR] {
            let source_dir = legacy_codex_home.join(dir_name);
            if source_dir.is_dir() {
                copy_dir_recursive(&source_dir, &shared_codex_home.join(dir_name)).with_context(
                    || {
                        format!(
                            "failed to migrate {} into shared Sirix storage",
                            source_dir.display()
                        )
                    },
                )?;
            }
        }

        let legacy_session_index = legacy_codex_home.join(SIRIX_SESSION_INDEX_FILE_NAME);
        if legacy_session_index.is_file() {
            append_file_contents(
                &legacy_session_index,
                &shared_codex_home.join(SIRIX_SESSION_INDEX_FILE_NAME),
            )?;
        }

        let legacy_config_path = legacy_codex_home.join("config.toml");
        if !legacy_config_path.is_file() {
            return Ok(());
        }

        let raw = fs::read_to_string(&legacy_config_path)
            .with_context(|| format!("failed to read {}", legacy_config_path.display()))?;
        let parsed = toml::from_str::<TomlValue>(&raw)
            .with_context(|| format!("failed to parse {}", legacy_config_path.display()))?;
        let Some(projects) = parsed
            .as_table()
            .and_then(|table| table.get("projects"))
            .and_then(TomlValue::as_table)
        else {
            return Ok(());
        };

        merge_projects_into_config_path(self.shared_codex_config_path().as_path(), projects)
    }

    fn load_rules_from_path(&self, path: &Path) -> anyhow::Result<ShellRulesConfig> {
        if !path.exists() {
            if path == self.global_shell_rules_path() || path == self.global_tool_rules_path() {
                let default_rules = ShellRulesConfig::default();
                self.save_rules_to_path(path, &default_rules)?;
                return Ok(default_rules);
            }
            return Ok(ShellRulesConfig::default());
        }

        let raw = fs::read_to_string(path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let mut rules = serde_json::from_str::<ShellRulesConfig>(&raw)
            .with_context(|| format!("failed to parse {}", path.display()))?;
        normalize_shell_rules(&mut rules);
        Ok(rules)
    }

    fn load_shell_rules_from_path(&self, path: &Path) -> anyhow::Result<ShellRulesConfig> {
        self.load_rules_from_path(path)
    }

    fn save_rules_to_path(&self, path: &Path, rules: &ShellRulesConfig) -> anyhow::Result<()> {
        let mut normalized = rules.clone();
        normalize_shell_rules(&mut normalized);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let serialized =
            serde_json::to_string_pretty(&normalized).context("failed to serialize shell rules")?;
        fs::write(path, serialized)
            .with_context(|| format!("failed to write {}", path.display()))?;
        Ok(())
    }

    fn save_shell_rules_to_path(
        &self,
        path: &Path,
        rules: &ShellRulesConfig,
    ) -> anyhow::Result<()> {
        self.save_rules_to_path(path, rules)
    }
}

fn install_bin_shim(source: &Path, target: &Path) -> anyhow::Result<()> {
    if target.exists() {
        let _ = fs::remove_file(target);
    }

    #[cfg(unix)]
    std::os::unix::fs::symlink(source, target).with_context(|| {
        format!(
            "failed to link {} -> {}",
            target.display(),
            source.display()
        )
    })?;

    #[cfg(windows)]
    fs::copy(source, target).with_context(|| {
        format!(
            "failed to copy {} -> {}",
            source.display(),
            target.display()
        )
    })?;

    Ok(())
}

fn resolve_agent(config: &SirixConfig, preferred: Option<&str>) -> anyhow::Result<AgentConfig> {
    if let Some(preferred) = preferred {
        if let Some(agent) = config
            .agents
            .iter()
            .find(|item| item.id == preferred && item.enabled && is_agent_launchable(config, item))
            .cloned()
        {
            return Ok(agent);
        }
    }

    // Sirix CLI 默认启动不显式传 agent_id，所以这里优先解析内置 `codex` Agent。
    // 这样 Provider/Model 页面上设置的默认模型会直接反映到 CLI 的默认启动结果。
    if let Some(default_agent) = config
        .agents
        .iter()
        .find(|item| {
            item.id == DEFAULT_AGENT_ID && item.enabled && is_agent_launchable(config, item)
        })
        .cloned()
    {
        return Ok(default_agent);
    }

    config
        .agents
        .iter()
        .find(|item| item.enabled && is_agent_launchable(config, item))
        .cloned()
        .context("no enabled agent configured")
}

fn is_agent_launchable(config: &SirixConfig, agent: &AgentConfig) -> bool {
    let Some(provider) = config
        .providers
        .iter()
        .find(|item| item.id == agent.provider_id && item.enabled)
    else {
        return false;
    };

    provider
        .models
        .iter()
        .any(|item| item.id == agent.model_id && item.enabled)
}

fn build_codex_bridge_toml(
    effective: SirixConfig,
    launch: &AiLaunchConfig,
    cwd: &Path,
    local_ws_port: u16,
    ai_session_id: Uuid,
) -> anyhow::Result<toml::map::Map<String, TomlValue>> {
    let mut root = toml::map::Map::<String, TomlValue>::new();
    root.insert(
        "model".to_string(),
        TomlValue::String(launch.model.id.clone()),
    );
    // Sirix routes every embedded Codex model request through a single local
    // proxy provider. That keeps the upstream Codex runtime unchanged while
    // still letting `/model` switch across Sirix providers by model slug.
    root.insert(
        "model_provider".to_string(),
        TomlValue::String(SIRIX_SESSION_PROXY_PROVIDER_ID.to_string()),
    );
    root.insert(
        "approval_policy".to_string(),
        TomlValue::String("never".to_string()),
    );
    root.insert(
        "sandbox_mode".to_string(),
        TomlValue::String("workspace-write".to_string()),
    );
    // Sirix owns this UX toggle and always writes it into the bridge config so the
    // embedded Codex TUI does not fall back to its own product defaults.
    root.insert(
        "close_model_without_confirmation".to_string(),
        TomlValue::Boolean(effective.cli.close_model_without_confirmation),
    );

    let instructions = build_agent_system_prompt(&effective, &launch.agent);
    if !instructions.trim().is_empty() {
        root.insert(
            "developer_instructions".to_string(),
            TomlValue::String(instructions),
        );
    }
    // Bake the Sirix profile identity and resolved shell mode into the bridge
    // config so spawned sub-agents can switch policy with their own role config
    // instead of inheriting the parent's runtime env file.
    root.insert(
        "sirix_agent_id".to_string(),
        TomlValue::String(launch.agent.id.clone()),
    );
    root.insert(
        "sirix_shell_mode".to_string(),
        TomlValue::String(shell_mode_override_for_agent(
            cwd,
            &launch.agent,
            &effective,
        )?),
    );

    let mut model_providers = toml::map::Map::<String, TomlValue>::new();
    let mut provider_value = toml::map::Map::<String, TomlValue>::new();
    provider_value.insert(
        "name".to_string(),
        TomlValue::String("Sirix Session Proxy".to_string()),
    );
    provider_value.insert(
        "base_url".to_string(),
        TomlValue::String(bridge_session_proxy_base_url(local_ws_port, ai_session_id)),
    );
    provider_value.insert(
        "wire_api".to_string(),
        TomlValue::String("responses".to_string()),
    );
    model_providers.insert(
        SIRIX_SESSION_PROXY_PROVIDER_ID.to_string(),
        TomlValue::Table(provider_value),
    );
    root.insert(
        "model_providers".to_string(),
        TomlValue::Table(model_providers),
    );

    let picker_models = build_bridge_models_for_session(
        &launch.session_providers,
        &launch.provider.id,
        &launch.model.id,
    );
    if !picker_models.is_empty() {
        root.insert("models".to_string(), TomlValue::Array(picker_models));
    }

    // Keep Desktop Server as the source of truth for per-agent skills, MCP,
    // and delegatable Sirix sub-agents. These sections intentionally use the
    // native Codex config shapes so the runtime can inject them through its
    // standard prompt/tool pipelines instead of Sirix-specific prompt text.
    root.insert(
        "skills".to_string(),
        build_sirix_skill_config(&effective, &launch.agent),
    );
    root.insert(
        "mcp_servers".to_string(),
        build_sirix_mcp_servers_table(&effective, &launch.agent)?,
    );
    let role_dir = launch.session_storage_dir.join(SIRIX_AGENT_ROLES_DIR);
    let role_files =
        write_sirix_agent_role_files(&effective, &launch.session_providers, cwd, &role_dir)?;
    root.insert(
        "agents".to_string(),
        build_sirix_agent_role_entries(&effective, &launch.agent, &role_files),
    );

    let mut sandbox_workspace_write = toml::map::Map::<String, TomlValue>::new();
    sandbox_workspace_write.insert(
        "writable_roots".to_string(),
        TomlValue::Array(vec![TomlValue::String(cwd.display().to_string())]),
    );
    sandbox_workspace_write.insert("network_access".to_string(), TomlValue::Boolean(true));
    root.insert(
        "sandbox_workspace_write".to_string(),
        TomlValue::Table(sandbox_workspace_write),
    );

    Ok(root)
}

fn shell_mode_override_for_agent(
    cwd: &Path,
    agent: &AgentConfig,
    _config: &SirixConfig,
) -> anyhow::Result<String> {
    // The bridge/role config only needs the final fallback mode for commands
    // that are not matched by any generated exec-policy prefix rule. Prefix
    // allow/deny entries are already materialized into the shared exec policy
    // file, so this helper only resolves the merged `allow / ask / deny` mode.
    //
    // We intentionally re-load the persisted shell-rules layers here so
    // sub-agent role files inherit the same Global -> Agent -> Workspace merge
    // semantics as the root session runtime.
    let effective_shell_mode = match agent.approval_mode {
        ApprovalMode::Allow => ApprovalMode::Allow,
        ApprovalMode::Deny => ApprovalMode::Deny,
        ApprovalMode::Ask => {
            let store = SirixConfigStore::new()?;
            store
                .effective_shell_rules_for_agent(cwd, agent, &ShellRulesConfig::default())?
                .mode
        }
    };

    let shell_mode = match effective_shell_mode {
        ApprovalMode::Allow => "allow",
        ApprovalMode::Ask => "ask",
        ApprovalMode::Deny => "deny",
    };

    Ok(shell_mode.to_string())
}

fn build_bridge_models_for_session(
    providers: &[ProviderConfig],
    active_provider_id: &str,
    default_model_id: &str,
) -> Vec<TomlValue> {
    let mut ordered_providers = providers
        .iter()
        .filter(|provider| provider.enabled)
        .collect::<Vec<_>>();
    // When different providers expose the same model slug, the local proxy
    // resolves that slug back to the active provider first. Reusing the same
    // priority here keeps the picker catalog and the proxy router consistent:
    // the first visible copy of a duplicate slug is always the one that would
    // actually receive the request after selection.
    ordered_providers.sort_by_key(|provider| {
        (
            provider.id != active_provider_id,
            provider.name.to_ascii_lowercase(),
            provider.id.to_ascii_lowercase(),
        )
    });

    let duplicate_model_ids = duplicate_session_text_model_ids(providers);
    let mut seen_picker_model_ids = HashSet::<String>::new();
    let mut models = Vec::new();
    for provider in ordered_providers {
        for model in provider.models.iter() {
            if !model.enabled || !matches!(model.model_kind, ModelKind::Text) {
                continue;
            }
            let picker_model_id = session_picker_model_id(provider, model, &duplicate_model_ids);
            if !seen_picker_model_ids.insert(picker_model_id.clone()) {
                continue;
            }
            let mut entry = toml::map::Map::<String, TomlValue>::new();
            entry.insert("id".to_string(), TomlValue::String(picker_model_id.clone()));
            entry.insert(
                "model".to_string(),
                TomlValue::String(picker_model_id.clone()),
            );
            entry.insert(
                "display_name".to_string(),
                TomlValue::String(model.display_name.clone()),
            );
            entry.insert(
                "description".to_string(),
                TomlValue::String(format!("Configured in Sirix provider {}", provider.name)),
            );
            entry.insert(
                "default_reasoning_effort".to_string(),
                TomlValue::String("none".to_string()),
            );
            entry.insert(
                "supported_reasoning_efforts".to_string(),
                TomlValue::Array(Vec::new()),
            );
            entry.insert(
                "supports_personality".to_string(),
                TomlValue::Boolean(false),
            );
            entry.insert(
                "additional_speed_tiers".to_string(),
                TomlValue::Array(Vec::new()),
            );
            // Mark the launch-selected model as the picker default so the embedded
            // Sirix CLI and the runtime model catalog stay aligned.
            entry.insert(
                "is_default".to_string(),
                TomlValue::Boolean(
                    provider.id == active_provider_id && model.id == default_model_id,
                ),
            );
            entry.insert("show_in_picker".to_string(), TomlValue::Boolean(true));
            entry.insert("supported_in_api".to_string(), TomlValue::Boolean(true));
            entry.insert(
                "input_modalities".to_string(),
                TomlValue::Array(if model.supports_images {
                    vec![
                        TomlValue::String("text".to_string()),
                        TomlValue::String("image".to_string()),
                    ]
                } else {
                    vec![TomlValue::String("text".to_string())]
                }),
            );
            models.push(TomlValue::Table(entry));
        }
    }
    models
}

pub(crate) fn duplicate_session_text_model_ids(providers: &[ProviderConfig]) -> HashSet<String> {
    let mut counts = HashMap::<String, usize>::new();
    for provider in providers.iter().filter(|provider| provider.enabled) {
        for model in provider.models.iter() {
            if !model.enabled || !matches!(model.model_kind, ModelKind::Text) {
                continue;
            }
            *counts.entry(model.id.clone()).or_default() += 1;
        }
    }

    counts
        .into_iter()
        .filter_map(|(model_id, count)| (count > 1).then_some(model_id))
        .collect()
}

pub(crate) fn session_picker_model_id(
    provider: &ProviderConfig,
    model: &ModelConfig,
    duplicate_model_ids: &HashSet<String>,
) -> String {
    if duplicate_model_ids.contains(model.id.as_str()) {
        // Sirix session model selection only sends one `model` string back from the embedded
        // Codex picker, without a separate provider id. When multiple providers expose the same
        // upstream slug, we must surface a stable provider-scoped alias so the selection can be
        // routed back to the intended provider instead of collapsing to "active provider wins".
        format!("{} @ {}", model.id, provider.id)
    } else {
        model.id.clone()
    }
}

pub(crate) fn resolve_session_picker_model<'a>(
    providers: &'a [ProviderConfig],
    picker_model_id: &str,
) -> Option<(&'a ProviderConfig, &'a ModelConfig)> {
    let trimmed_picker_model_id = picker_model_id.trim();
    if trimmed_picker_model_id.is_empty() {
        return None;
    }

    let duplicate_model_ids = duplicate_session_text_model_ids(providers);
    for provider in providers.iter().filter(|provider| provider.enabled) {
        for model in provider.models.iter() {
            if !model.enabled || !matches!(model.model_kind, ModelKind::Text) {
                continue;
            }
            let candidate = session_picker_model_id(provider, model, &duplicate_model_ids);
            if candidate == trimmed_picker_model_id {
                return Some((provider, model));
            }
        }
    }
    None
}

fn bridge_session_proxy_base_url(local_ws_port: u16, ai_session_id: Uuid) -> String {
    format!("http://127.0.0.1:{local_ws_port}/ai/sessions/{ai_session_id}/provider/v1")
}

fn is_builtin_codex_agent(agent_id: &str) -> bool {
    agent_id == DEFAULT_AGENT_ID
}

fn first_enabled_text_model(config: &SirixConfig) -> Option<(&ProviderConfig, &ModelConfig)> {
    config.providers.iter().find_map(|provider| {
        if !provider.enabled {
            return None;
        }
        provider
            .models
            .iter()
            .find(|model| model.enabled && matches!(model.model_kind, ModelKind::Text))
            .map(|model| (provider, model))
    })
}

fn migrate_default_agent_to_codex(config: &mut SirixConfig) {
    let legacy_index = config
        .agents
        .iter()
        .position(|agent| agent.id == LEGACY_DEFAULT_AGENT_ID);
    let codex_index = config
        .agents
        .iter()
        .position(|agent| is_builtin_codex_agent(agent.id.as_str()));

    match (legacy_index, codex_index) {
        (Some(legacy_index), None) => {
            let agent = &mut config.agents[legacy_index];
            agent.id = DEFAULT_AGENT_ID.to_string();
            if agent.name.trim().is_empty() || agent.name == "Default Agent" {
                agent.name = DEFAULT_AGENT_NAME.to_string();
            }
            if agent.description.trim().is_empty()
                || agent.description == "Default Sirix coding agent."
            {
                agent.description = DEFAULT_AGENT_DESCRIPTION.to_string();
            }
        }
        (Some(legacy_index), Some(codex_index)) if legacy_index != codex_index => {
            config.agents.remove(legacy_index);
        }
        _ => {}
    }
}

fn normalize_builtin_codex_agent(agent: &mut AgentConfig, default_builtin_tools: &[String]) {
    // Keep the built-in Codex profile aligned with the embedded Codex runtime.
    // Sirix may still choose provider/model, fallback, MCP, skills, and sub-agents
    // for this profile, but it should not carry a custom prompt overlay or a
    // partial builtin-tool set that drifts away from Codex defaults.
    if !is_builtin_codex_agent(agent.id.as_str()) {
        return;
    }

    agent.id = DEFAULT_AGENT_ID.to_string();
    if agent.name.trim().is_empty() {
        agent.name = DEFAULT_AGENT_NAME.to_string();
    }
    if agent.description.trim().is_empty() {
        agent.description = DEFAULT_AGENT_DESCRIPTION.to_string();
    }
    agent.enabled = true;
    agent.system_prompt.clear();
    agent.builtin_tool_ids = default_builtin_tools.to_vec();
}

fn normalize_sirix_config(config: &mut SirixConfig) {
    // Keep legacy config migration centralized here so the rest of the runtime
    // can rely on the newer Agent schema without duplicating fallback logic.
    let default_builtin_tools = default_builtin_tool_ids();
    migrate_default_agent_to_codex(config);
    let all_skill_ids = config
        .skills
        .iter()
        .map(|skill| skill.id.clone())
        .collect::<Vec<_>>();
    let all_mcp_ids = config
        .mcp_servers
        .iter()
        .map(|server| server.id.clone())
        .collect::<Vec<_>>();

    for agent in &mut config.agents {
        if agent.builtin_tool_ids.is_empty() && agent.legacy_builtin_tools_enabled.unwrap_or(true) {
            agent.builtin_tool_ids = default_builtin_tools.clone();
        }

        if agent.skill_ids.is_empty() {
            if !agent.legacy_enabled_skill_ids.is_empty() {
                agent.skill_ids = agent.legacy_enabled_skill_ids.clone();
            } else if !agent.legacy_disabled_skill_ids.is_empty() {
                let disabled = agent
                    .legacy_disabled_skill_ids
                    .iter()
                    .collect::<HashSet<_>>();
                agent.skill_ids = all_skill_ids
                    .iter()
                    .filter(|item| !disabled.contains(item))
                    .cloned()
                    .collect();
            }
        }

        if agent.mcp_server_ids.is_empty() {
            if !agent.legacy_enabled_mcp_server_ids.is_empty() {
                agent.mcp_server_ids = agent.legacy_enabled_mcp_server_ids.clone();
            } else if !agent.legacy_disabled_mcp_server_ids.is_empty() {
                let disabled = agent
                    .legacy_disabled_mcp_server_ids
                    .iter()
                    .collect::<HashSet<_>>();
                agent.mcp_server_ids = all_mcp_ids
                    .iter()
                    .filter(|item| !disabled.contains(item))
                    .cloned()
                    .collect();
            }
        }

        if matches!(agent.approval_mode, ApprovalMode::Allow) {
            if let Some(shell_rule) = agent
                .legacy_capability_rules
                .iter()
                .find(|rule| rule.key == "builtin.shell")
            {
                agent.approval_mode = shell_rule.approval_mode.clone();
            }
        }

        normalize_shell_rules(&mut agent.shell_rules);
        normalize_shell_rules(&mut agent.tool_rules);

        normalize_builtin_codex_agent(agent, &default_builtin_tools);
    }

    if !config
        .agents
        .iter()
        .any(|agent| is_builtin_codex_agent(agent.id.as_str()))
    {
        if let Some((provider, model)) = first_enabled_text_model(config) {
            config.agents.insert(
                0,
                AgentConfig {
                    id: DEFAULT_AGENT_ID.to_string(),
                    name: DEFAULT_AGENT_NAME.to_string(),
                    description: DEFAULT_AGENT_DESCRIPTION.to_string(),
                    provider_id: provider.id.clone(),
                    model_id: model.id.clone(),
                    fallback_provider_id: String::new(),
                    fallback_model_id: String::new(),
                    system_prompt: String::new(),
                    approval_mode: ApprovalMode::Ask,
                    shell_rules: ShellRulesConfig::default(),
                    tool_rules: ToolRulesConfig::default(),
                    builtin_tool_ids: default_builtin_tools,
                    skill_ids: Vec::new(),
                    mcp_server_ids: Vec::new(),
                    sub_agent_ids: Vec::new(),
                    enabled: true,
                    legacy_builtin_tools_enabled: None,
                    legacy_enabled_skill_ids: Vec::new(),
                    legacy_disabled_skill_ids: Vec::new(),
                    legacy_enabled_mcp_server_ids: Vec::new(),
                    legacy_disabled_mcp_server_ids: Vec::new(),
                    legacy_capability_rules: Vec::new(),
                },
            );
        }
    }
}

pub fn normalized_sirix_config(config: &SirixConfig) -> SirixConfig {
    let mut normalized = config.clone();
    normalize_sirix_config(&mut normalized);
    normalized
}

pub fn validate_sirix_config(config: &SirixConfig) -> anyhow::Result<()> {
    ensure_unique_ids(
        config.providers.iter().map(|item| item.id.as_str()),
        "provider",
    )?;
    ensure_unique_ids(config.skills.iter().map(|item| item.id.as_str()), "skill")?;
    ensure_unique_ids(
        config.mcp_servers.iter().map(|item| item.id.as_str()),
        "mcp server",
    )?;
    ensure_unique_ids(config.agents.iter().map(|item| item.id.as_str()), "agent")?;

    let provider_ids = config
        .providers
        .iter()
        .map(|item| item.id.as_str())
        .collect::<HashSet<_>>();
    let skill_ids = config
        .skills
        .iter()
        .map(|item| item.id.as_str())
        .collect::<HashSet<_>>();
    let mcp_ids = config
        .mcp_servers
        .iter()
        .map(|item| item.id.as_str())
        .collect::<HashSet<_>>();
    let agent_ids = config
        .agents
        .iter()
        .map(|item| item.id.as_str())
        .collect::<HashSet<_>>();
    let builtin_tool_ids = builtin_tool_catalog().into_iter().collect::<HashSet<_>>();

    for provider in &config.providers {
        if provider.id.trim().is_empty() {
            anyhow::bail!("provider id cannot be empty");
        }
        if provider.name.trim().is_empty() {
            anyhow::bail!("provider {} name cannot be empty", provider.id);
        }
        if provider.default_context_window == Some(0) {
            anyhow::bail!(
                "provider {} default_context_window must be greater than zero",
                provider.id
            );
        }
        ensure_unique_ids(provider.models.iter().map(|item| item.id.as_str()), "model")?;
        for model in &provider.models {
            if model.id.trim().is_empty() {
                anyhow::bail!("provider {} has model with empty id", provider.id);
            }
            if model.display_name.trim().is_empty() {
                anyhow::bail!("model {} display_name cannot be empty", model.id);
            }
            if model.context_window == Some(0) {
                anyhow::bail!(
                    "model {} context_window must be greater than zero",
                    model.id
                );
            }
        }
    }

    for skill in &config.skills {
        if skill.id.trim().is_empty() {
            anyhow::bail!("skill id cannot be empty");
        }
        if skill.name.trim().is_empty() {
            anyhow::bail!("skill {} name cannot be empty", skill.id);
        }
        if skill.path.trim().is_empty() {
            anyhow::bail!("skill {} path cannot be empty", skill.id);
        }
        if skill.enabled {
            validate_skill_path(skill)?;
        }
    }

    for server in &config.mcp_servers {
        validate_mcp_server_config(server)?;
    }

    for agent in &config.agents {
        if agent.id.trim().is_empty() {
            anyhow::bail!("agent id cannot be empty");
        }
        if agent.name.trim().is_empty() {
            anyhow::bail!("agent {} name cannot be empty", agent.id);
        }
        if !agent.fallback_provider_id.trim().is_empty()
            ^ !agent.fallback_model_id.trim().is_empty()
        {
            anyhow::bail!(
                "agent {} fallback provider/model must either both be set or both be empty",
                agent.id
            );
        }
        if !provider_ids.contains(agent.provider_id.as_str()) {
            anyhow::bail!(
                "agent {} references unknown provider {}",
                agent.id,
                agent.provider_id
            );
        }
        let Some(provider) = config
            .providers
            .iter()
            .find(|item| item.id == agent.provider_id)
        else {
            anyhow::bail!(
                "agent {} references missing provider {}",
                agent.id,
                agent.provider_id
            );
        };
        if !provider.models.iter().any(|item| item.id == agent.model_id) {
            anyhow::bail!(
                "agent {} references unknown model {} for provider {}",
                agent.id,
                agent.model_id,
                agent.provider_id
            );
        }
        if !agent.fallback_provider_id.trim().is_empty() {
            let Some(fallback_provider) = config
                .providers
                .iter()
                .find(|item| item.id == agent.fallback_provider_id)
            else {
                anyhow::bail!(
                    "agent {} references unknown fallback provider {}",
                    agent.id,
                    agent.fallback_provider_id
                );
            };
            if !fallback_provider
                .models
                .iter()
                .any(|item| item.id == agent.fallback_model_id)
            {
                anyhow::bail!(
                    "agent {} references unknown fallback model {} for provider {}",
                    agent.id,
                    agent.fallback_model_id,
                    agent.fallback_provider_id
                );
            }
        }
        ensure_known_ids(
            &agent.skill_ids,
            &skill_ids,
            &format!("agent {} skill_ids", agent.id),
        )?;
        ensure_known_ids(
            &agent.mcp_server_ids,
            &mcp_ids,
            &format!("agent {} mcp_server_ids", agent.id),
        )?;
        ensure_known_ids(
            &agent.sub_agent_ids,
            &agent_ids,
            &format!("agent {} sub_agent_ids", agent.id),
        )?;
        ensure_known_ids(
            &agent.builtin_tool_ids,
            &builtin_tool_ids,
            &format!("agent {} builtin_tool_ids", agent.id),
        )?;
    }

    Ok(())
}

pub fn effective_model_context_window(provider: &ProviderConfig, model: &ModelConfig) -> u32 {
    // 用户现在可以只在 Provider 上配置默认上下文窗口，而把具体 Model 留空。
    // 这里统一收敛“model 显式值 -> provider 默认值 -> Sirix 供应商兜底”的生效顺序，
    // 保证设置页、模型发现结果和运行时暴露给 CLI 的 catalog 使用同一套结果。
    model
        .context_window
        .or(provider.default_context_window)
        .unwrap_or_else(|| infer_provider_default_context_window(&provider.kind, &model.id))
}

pub fn infer_provider_default_context_window(kind: &ProviderKind, model_id: &str) -> u32 {
    match kind {
        ProviderKind::Anthropic => 200_000,
        ProviderKind::Gemini => 1_048_576,
        ProviderKind::OpenAiResponses
        | ProviderKind::OpenAiCodexOauth
        | ProviderKind::OpenAiCodexApi
            if model_id.starts_with("gpt-5") =>
        {
            400_000
        }
        ProviderKind::OpenAiResponses
        | ProviderKind::OpenAiCodexOauth
        | ProviderKind::OpenAiCodexApi => 200_000,
        ProviderKind::OpenAiCompatible => 128_000,
    }
}

fn parse_config_with_compat(raw: &str, source: &Path) -> anyhow::Result<SirixConfig> {
    let mut parsed = match toml::from_str::<SirixConfig>(raw) {
        Ok(parsed) => parsed,
        Err(primary_error) => parse_legacy_codex_config(raw).with_context(|| {
            format!(
                "failed to parse {} as Sirix config ({primary_error})",
                source.display()
            )
        })?,
    };
    normalize_sirix_config(&mut parsed);
    Ok(parsed)
}

fn parse_legacy_codex_config(raw: &str) -> anyhow::Result<SirixConfig> {
    let value = parse_toml_document_value(raw).context("legacy config is not valid TOML")?;
    let table = value
        .as_table()
        .context("legacy config root must be a table")?;
    if !looks_like_legacy_codex_config(table) {
        anyhow::bail!("config does not match supported legacy Codex format");
    }

    let mut config = SirixConfig::default();
    if let Some(instructions) = table
        .get("instructions")
        .and_then(TomlValue::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        config.cli.supplemental_system_prompt = instructions.to_string();
    }
    if let Some(close_without_confirmation) = table
        .get("close_model_without_confirmation")
        .and_then(TomlValue::as_bool)
    {
        config.cli.close_model_without_confirmation = close_without_confirmation;
    }

    let model_id = table
        .get("model")
        .and_then(TomlValue::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(DEFAULT_MODEL_ID)
        .to_string();
    let context_window = table
        .get("model_context_window")
        .and_then(toml_integer_to_u32)
        .unwrap_or(200_000);

    if let Some(providers) = table.get("model_providers").and_then(TomlValue::as_table) {
        let converted = providers
            .iter()
            .map(|(id, value)| {
                legacy_provider_to_sirix(id, value, &model_id, context_window)
                    .with_context(|| format!("failed to parse legacy model provider {id}"))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        if !converted.is_empty() {
            config.providers = converted;
        }
    } else if let Some(default_provider) = config.providers.first_mut() {
        default_provider.models = vec![ModelConfig {
            id: model_id.clone(),
            display_name: model_id.clone(),
            model_kind: ModelKind::Text,
            context_window: None,
            supports_images: true,
            enabled: true,
        }];
        default_provider.default_context_window = Some(context_window);
    }

    if let Some(skills_value) = table.get("skills") {
        if let Some(skills) = parse_legacy_skills(skills_value)?.filter(|items| !items.is_empty()) {
            config.skills = skills;
        }
    }

    if let Some(mcp_value) = table.get("mcp_servers") {
        if let Some(mcp_servers) =
            parse_legacy_mcp_servers(mcp_value)?.filter(|items| !items.is_empty())
        {
            config.mcp_servers = mcp_servers;
        }
    }

    let mut provider_id = table
        .get("model_provider")
        .and_then(TomlValue::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(DEFAULT_PROVIDER_ID)
        .to_string();
    if !config
        .providers
        .iter()
        .any(|item| item.id == provider_id && item.enabled)
    {
        provider_id = config
            .providers
            .iter()
            .find(|item| item.enabled)
            .map(|item| item.id.clone())
            .unwrap_or_else(|| DEFAULT_PROVIDER_ID.to_string());
    }

    let mut agent = SirixConfig::default()
        .agents
        .into_iter()
        .next()
        .context("missing default agent template")?;
    agent.provider_id = provider_id;
    agent.model_id = model_id;
    config.agents = vec![agent];

    Ok(config)
}

fn extract_cli_close_confirmation_override(
    raw: &str,
    source: &Path,
) -> anyhow::Result<Option<bool>> {
    let value = parse_toml_document_value(raw).with_context(|| {
        format!(
            "failed to parse {} while inspecting CLI close toggle",
            source.display()
        )
    })?;
    let table = value.as_table().with_context(|| {
        format!(
            "{} root must be a table while inspecting CLI close toggle",
            source.display()
        )
    })?;

    if let Some(value) = table
        .get("cli")
        .and_then(TomlValue::as_table)
        .and_then(|cli| cli.get("close_model_without_confirmation"))
        .and_then(TomlValue::as_bool)
    {
        return Ok(Some(value));
    }

    Ok(table
        .get("close_model_without_confirmation")
        .and_then(TomlValue::as_bool))
}

fn looks_like_legacy_codex_config(table: &toml::map::Map<String, TomlValue>) -> bool {
    if ["version", "cli", "providers", "mcp", "agents"]
        .iter()
        .any(|key| table.contains_key(*key))
    {
        return false;
    }

    [
        "model",
        "model_provider",
        "model_providers",
        "profiles",
        "preferred_auth_method",
        "sandbox_workspace_write",
        "web_search",
        "disable_response_storage",
    ]
    .iter()
    .any(|key| table.contains_key(*key))
        || (table.contains_key("mcp_servers")
            && ["instructions", "model_context_window", "skills"]
                .iter()
                .any(|key| table.contains_key(*key)))
}

fn legacy_provider_to_sirix(
    id: &str,
    value: &TomlValue,
    default_model_id: &str,
    context_window: u32,
) -> anyhow::Result<ProviderConfig> {
    let table = value
        .as_table()
        .with_context(|| format!("legacy provider {id} must be a table"))?;
    let headers_json = match table.get("http_headers") {
        Some(headers) => serde_json::to_string(&json_from_toml(headers.clone()))
            .context("failed to serialize legacy provider headers")?,
        None => "{}".to_string(),
    };
    Ok(ProviderConfig {
        id: id.to_string(),
        name: table
            .get("name")
            .and_then(TomlValue::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(id)
            .to_string(),
        kind: legacy_provider_kind(table),
        default_context_window: Some(context_window),
        base_url: table
            .get("base_url")
            .and_then(TomlValue::as_str)
            .unwrap_or_default()
            .to_string(),
        api_key_env: table
            .get("env_key")
            .or_else(|| table.get("api_key_env"))
            .and_then(TomlValue::as_str)
            .unwrap_or_default()
            .to_string(),
        api_key: String::new(),
        headers_json,
        enabled: !table
            .get("disabled")
            .and_then(TomlValue::as_bool)
            .unwrap_or(false),
        models: vec![ModelConfig {
            id: default_model_id.to_string(),
            display_name: default_model_id.to_string(),
            model_kind: ModelKind::Text,
            context_window: None,
            supports_images: true,
            enabled: true,
        }],
    })
}

fn legacy_provider_kind(table: &toml::map::Map<String, TomlValue>) -> ProviderKind {
    match table.get("wire_api").and_then(TomlValue::as_str) {
        Some("responses") => ProviderKind::OpenAiResponses,
        _ => ProviderKind::OpenAiCompatible,
    }
}

fn parse_legacy_skills(value: &TomlValue) -> anyhow::Result<Option<Vec<SkillConfig>>> {
    let table = match value.as_table() {
        Some(table) => table,
        None => return Ok(None),
    };
    let Some(entries) = table.get("config").and_then(TomlValue::as_array) else {
        return Ok(None);
    };

    let mut skills = Vec::with_capacity(entries.len());
    for (index, entry) in entries.iter().enumerate() {
        let Some(item) = entry.as_table() else {
            continue;
        };
        let Some(path) = item
            .get("path")
            .and_then(TomlValue::as_str)
            .filter(|value| !value.trim().is_empty())
        else {
            continue;
        };
        let name = item
            .get("name")
            .and_then(TomlValue::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(ToString::to_string)
            .unwrap_or_else(|| legacy_name_from_path(path, "Skill", index));
        skills.push(SkillConfig {
            id: item
                .get("id")
                .and_then(TomlValue::as_str)
                .filter(|value| !value.trim().is_empty())
                .map(ToString::to_string)
                .unwrap_or_else(|| legacy_id_from_label(&name, "skill", index)),
            name,
            path: path.to_string(),
            enabled: item
                .get("enabled")
                .and_then(TomlValue::as_bool)
                .unwrap_or(true),
            allow_outside_sandbox: item
                .get("allow_outside_sandbox")
                .and_then(TomlValue::as_bool)
                .unwrap_or(false),
        });
    }

    Ok(Some(skills))
}

fn parse_legacy_mcp_servers(value: &TomlValue) -> anyhow::Result<Option<Vec<McpServerConfig>>> {
    let table = match value.as_table() {
        Some(table) => table,
        None => return Ok(None),
    };

    let mut servers = Vec::with_capacity(table.len());
    for (id, entry) in table {
        let Some(item) = entry.as_table() else {
            continue;
        };
        let json_config = toml::to_string_pretty(entry)
            .with_context(|| format!("failed to serialize legacy MCP config for {id}"))?;
        servers.push(McpServerConfig {
            id: id.to_string(),
            name: item
                .get("name")
                .and_then(TomlValue::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(id)
                .to_string(),
            enabled: !item
                .get("disabled")
                .and_then(TomlValue::as_bool)
                .unwrap_or(false),
            approval_mode: ApprovalMode::Allow,
            enabled_tools: item
                .get("enabled_tools")
                .and_then(TomlValue::as_array)
                .map(|values| toml_string_array(values))
                .unwrap_or_default(),
            disabled_tools: item
                .get("disabled_tools")
                .and_then(TomlValue::as_array)
                .map(|values| toml_string_array(values))
                .unwrap_or_default(),
            json_config,
        });
    }

    Ok(Some(servers))
}

fn toml_integer_to_u32(value: &TomlValue) -> Option<u32> {
    value
        .as_integer()
        .and_then(|item| u32::try_from(item).ok())
        .filter(|item| *item > 0)
}

fn toml_string_array(values: &[TomlValue]) -> Vec<String> {
    values
        .iter()
        .filter_map(TomlValue::as_str)
        .map(ToString::to_string)
        .collect()
}

fn json_from_toml(value: TomlValue) -> serde_json::Value {
    match value {
        TomlValue::String(value) => serde_json::Value::String(value),
        TomlValue::Integer(value) => serde_json::Value::Number(value.into()),
        TomlValue::Float(value) => serde_json::Number::from_f64(value)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::Null),
        TomlValue::Boolean(value) => serde_json::Value::Bool(value),
        TomlValue::Datetime(value) => serde_json::Value::String(value.to_string()),
        TomlValue::Array(values) => {
            serde_json::Value::Array(values.into_iter().map(json_from_toml).collect())
        }
        TomlValue::Table(values) => serde_json::Value::Object(
            values
                .into_iter()
                .map(|(key, value)| (key, json_from_toml(value)))
                .collect(),
        ),
    }
}

fn legacy_name_from_path(path: &str, fallback: &str, index: usize) -> String {
    Path::new(path)
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| format!("{fallback} {}", index + 1))
}

fn legacy_id_from_label(label: &str, fallback: &str, index: usize) -> String {
    let normalized = label
        .chars()
        .map(|char| {
            if char.is_ascii_alphanumeric() {
                char.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .split('-')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    if normalized.is_empty() {
        return format!("{fallback}-{}", index + 1);
    }
    normalized
}

fn toml_from_json(value: serde_json::Value) -> TomlValue {
    match value {
        serde_json::Value::Null => TomlValue::String(String::new()),
        serde_json::Value::Bool(value) => TomlValue::Boolean(value),
        serde_json::Value::Number(value) => {
            if let Some(value) = value.as_i64() {
                TomlValue::Integer(value)
            } else if let Some(value) = value.as_f64() {
                TomlValue::Float(value)
            } else {
                TomlValue::String(value.to_string())
            }
        }
        serde_json::Value::String(value) => TomlValue::String(value),
        serde_json::Value::Array(values) => {
            TomlValue::Array(values.into_iter().map(toml_from_json).collect())
        }
        serde_json::Value::Object(map) => TomlValue::Table(
            map.into_iter()
                .map(|(key, value)| (key, toml_from_json(value)))
                .collect(),
        ),
    }
}

fn parse_toml_document_value(raw: &str) -> anyhow::Result<TomlValue> {
    // `toml` 0.9 parses `Value` as a single literal/inline value, not a complete
    // document. Sirix config files and many imported Codex-compatible config
    // fragments are full TOML documents with table headers, so normalize them to
    // a top-level table here.
    toml::from_str::<toml::Table>(raw)
        .map(TomlValue::Table)
        .context("failed to parse TOML document")
}

fn parse_mcp_config_value(raw: &str) -> anyhow::Result<TomlValue> {
    parse_toml_document_value(raw)
        .or_else(|_| toml::from_str::<TomlValue>(raw).context("failed to parse TOML value"))
        .or_else(|_| toml::from_str::<serde_json::Value>(raw).map(toml_from_json))
        .context("failed to parse MCP config as TOML or JSON")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum McpTransportKind {
    Stdio,
    Http,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpProbeTarget {
    Stdio {
        command: String,
        args: Vec<String>,
        env: BTreeMap<String, String>,
    },
    Http {
        url: String,
    },
}

pub fn extract_mcp_probe_target(server: &McpServerConfig) -> anyhow::Result<McpProbeTarget> {
    let value = parse_mcp_config_value(&server.json_config)
        .with_context(|| format!("invalid mcp config for {}", server.id))?;
    let table = value
        .as_table()
        .context("MCP config must be a table/object")?;
    let transport = table.get("transport").and_then(TomlValue::as_table);

    match infer_mcp_transport(&value)? {
        McpTransportKind::Stdio => {
            let command = lookup_non_empty_string(table, &["command", "cmd"])
                .or_else(|| {
                    transport
                        .and_then(|nested| lookup_non_empty_string(nested, &["command", "cmd"]))
                })
                .context("stdio MCP transport requires command/cmd")?;
            let args = match lookup_string_array(table, &["args"])? {
                Some(args) => args,
                None => match transport {
                    Some(nested) => lookup_string_array(nested, &["args"])?.unwrap_or_default(),
                    None => Vec::new(),
                },
            };
            let env = match lookup_string_map(table, &["env"])? {
                Some(env) => env,
                None => match transport {
                    Some(nested) => lookup_string_map(nested, &["env"])?.unwrap_or_default(),
                    None => BTreeMap::new(),
                },
            };
            Ok(McpProbeTarget::Stdio { command, args, env })
        }
        McpTransportKind::Http => {
            let url = lookup_non_empty_string(table, &["url", "endpoint"])
                .or_else(|| {
                    transport
                        .and_then(|nested| lookup_non_empty_string(nested, &["url", "endpoint"]))
                })
                .context("http MCP transport requires url/endpoint")?;
            Ok(McpProbeTarget::Http { url })
        }
    }
}

fn infer_mcp_transport(value: &TomlValue) -> anyhow::Result<McpTransportKind> {
    let table = value
        .as_table()
        .context("MCP config must be a table/object")?;
    if has_non_empty_string(table, &["command", "cmd"]) {
        return Ok(McpTransportKind::Stdio);
    }
    if has_non_empty_string(table, &["url", "endpoint"]) {
        return Ok(McpTransportKind::Http);
    }

    if let Some(transport_value) = table.get("transport") {
        if let Some(transport_name) = transport_value.as_str() {
            return parse_transport_kind(transport_name);
        }
        if let Some(transport) = transport_value.as_table() {
            if let Some(transport_name) = transport.get("type").and_then(TomlValue::as_str) {
                return parse_transport_kind(transport_name);
            }
            if has_non_empty_string(transport, &["command", "cmd"]) {
                return Ok(McpTransportKind::Stdio);
            }
            if has_non_empty_string(transport, &["url", "endpoint"]) {
                return Ok(McpTransportKind::Http);
            }
        }
    }

    anyhow::bail!("unable to infer MCP transport from config")
}

fn parse_transport_kind(raw: &str) -> anyhow::Result<McpTransportKind> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "stdio" => Ok(McpTransportKind::Stdio),
        "http" | "https" | "sse" | "streamable_http" | "streamable-http" => {
            Ok(McpTransportKind::Http)
        }
        other => anyhow::bail!("unsupported MCP transport {other}"),
    }
}

fn has_non_empty_string(table: &toml::map::Map<String, TomlValue>, keys: &[&str]) -> bool {
    keys.iter().any(|key| {
        table
            .get(*key)
            .and_then(TomlValue::as_str)
            .is_some_and(|value| !value.trim().is_empty())
    })
}

fn lookup_non_empty_string(
    table: &toml::map::Map<String, TomlValue>,
    keys: &[&str],
) -> Option<String> {
    keys.iter().find_map(|key| {
        table
            .get(*key)
            .and_then(TomlValue::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    })
}

fn lookup_string_array(
    table: &toml::map::Map<String, TomlValue>,
    keys: &[&str],
) -> anyhow::Result<Option<Vec<String>>> {
    for key in keys {
        if let Some(value) = table.get(*key) {
            let array = value
                .as_array()
                .with_context(|| format!("{key} must be an array"))?;
            return Ok(Some(
                array
                    .iter()
                    .filter_map(TomlValue::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToString::to_string)
                    .collect(),
            ));
        }
    }
    Ok(None)
}

fn lookup_string_map(
    table: &toml::map::Map<String, TomlValue>,
    keys: &[&str],
) -> anyhow::Result<Option<BTreeMap<String, String>>> {
    for key in keys {
        if let Some(value) = table.get(*key) {
            let map = value
                .as_table()
                .with_context(|| format!("{key} must be a table/object"))?;
            let mut output = BTreeMap::new();
            for (entry_key, entry_value) in map {
                if let Some(entry_value) = entry_value.as_str().map(str::trim) {
                    output.insert(entry_key.clone(), entry_value.to_string());
                }
            }
            return Ok(Some(output));
        }
    }
    Ok(None)
}

fn ensure_unique_ids<'a>(
    ids: impl IntoIterator<Item = &'a str>,
    entity_name: &str,
) -> anyhow::Result<()> {
    let mut seen = HashSet::new();
    for id in ids {
        let normalized = id.trim();
        if normalized.is_empty() {
            anyhow::bail!("{entity_name} id cannot be empty");
        }
        if !seen.insert(normalized.to_string()) {
            anyhow::bail!("duplicate {entity_name} id: {normalized}");
        }
    }
    Ok(())
}

fn ensure_known_ids(ids: &[String], known: &HashSet<&str>, label: &str) -> anyhow::Result<()> {
    let mut seen = HashSet::new();
    for id in ids {
        let normalized = id.trim();
        if normalized.is_empty() {
            anyhow::bail!("{label} contains empty id");
        }
        if !seen.insert(normalized.to_string()) {
            anyhow::bail!("{label} contains duplicate id: {normalized}");
        }
        if !known.contains(normalized) {
            anyhow::bail!("{label} references unknown id: {normalized}");
        }
    }
    Ok(())
}

fn validate_skill_path(skill: &SkillConfig) -> anyhow::Result<()> {
    let path = Path::new(skill.path.trim());
    if !path.is_dir() {
        anyhow::bail!("skill {} path does not exist: {}", skill.id, path.display());
    }
    let skill_md = path.join("SKILL.md");
    if !skill_md.is_file() {
        anyhow::bail!(
            "skill {} is missing SKILL.md under {}",
            skill.id,
            path.display()
        );
    }
    Ok(())
}

fn validate_mcp_server_config(server: &McpServerConfig) -> anyhow::Result<()> {
    if server.id.trim().is_empty() {
        anyhow::bail!("mcp server id cannot be empty");
    }
    if server.name.trim().is_empty() {
        anyhow::bail!("mcp server {} name cannot be empty", server.id);
    }
    let value = parse_mcp_config_value(&server.json_config)
        .with_context(|| format!("invalid mcp config for {}", server.id))?;
    match infer_mcp_transport(&value)
        .with_context(|| format!("mcp server {} transport validation failed", server.id))?
    {
        McpTransportKind::Stdio => {
            let table = value.as_table().context("invalid MCP config table")?;
            let transport = table.get("transport").and_then(TomlValue::as_table);
            let has_command = has_non_empty_string(table, &["command", "cmd"])
                || transport
                    .is_some_and(|nested| has_non_empty_string(nested, &["command", "cmd"]));
            if !has_command {
                anyhow::bail!(
                    "mcp server {} stdio transport requires command/cmd",
                    server.id
                );
            }
        }
        McpTransportKind::Http => {
            let table = value.as_table().context("invalid MCP config table")?;
            let transport = table.get("transport").and_then(TomlValue::as_table);
            let has_url = has_non_empty_string(table, &["url", "endpoint"])
                || transport
                    .is_some_and(|nested| has_non_empty_string(nested, &["url", "endpoint"]));
            if !has_url {
                anyhow::bail!(
                    "mcp server {} http transport requires url/endpoint",
                    server.id
                );
            }
        }
    }

    let enabled_tools = server
        .enabled_tools
        .iter()
        .map(|item| item.trim())
        .filter(|item| !item.is_empty())
        .collect::<HashSet<_>>();
    if enabled_tools.len()
        != server
            .enabled_tools
            .iter()
            .filter(|item| !item.trim().is_empty())
            .count()
    {
        anyhow::bail!("mcp server {} enabled_tools contains duplicates", server.id);
    }
    let disabled_tools = server
        .disabled_tools
        .iter()
        .map(|item| item.trim())
        .filter(|item| !item.is_empty())
        .collect::<HashSet<_>>();
    if disabled_tools.len()
        != server
            .disabled_tools
            .iter()
            .filter(|item| !item.trim().is_empty())
            .count()
    {
        anyhow::bail!(
            "mcp server {} disabled_tools contains duplicates",
            server.id
        );
    }
    if enabled_tools
        .iter()
        .any(|item| disabled_tools.contains(item))
    {
        anyhow::bail!(
            "mcp server {} tool cannot exist in both enabled_tools and disabled_tools",
            server.id
        );
    }
    Ok(())
}

fn merge_sirix_config(base: SirixConfig, overlay: SirixConfig) -> SirixConfig {
    SirixConfig {
        version: overlay.version.max(base.version),
        cli: merge_cli_settings(base.cli, overlay.cli),
        providers: if overlay.providers.is_empty() {
            base.providers
        } else {
            overlay.providers
        },
        skills: if overlay.skills.is_empty() {
            base.skills
        } else {
            overlay.skills
        },
        mcp: if overlay.mcp == McpGlobalConfig::default() {
            base.mcp
        } else {
            overlay.mcp
        },
        mcp_servers: if overlay.mcp_servers.is_empty() {
            base.mcp_servers
        } else {
            overlay.mcp_servers
        },
        agents: if overlay.agents.is_empty() {
            base.agents
        } else {
            overlay.agents
        },
    }
}

fn merge_shell_rules(base: ShellRulesConfig, overlay: ShellRulesConfig) -> ShellRulesConfig {
    let mut merged = ShellRulesConfig {
        version: base.version.max(overlay.version),
        mode: overlay.mode,
        allow: base.allow,
        deny: base.deny,
    };

    for rule in overlay.allow {
        upsert_shell_rule(&mut merged.allow, &rule);
        prune_opposite_rules(&mut merged.deny, &rule);
    }
    for rule in overlay.deny {
        upsert_shell_rule(&mut merged.deny, &rule);
        prune_opposite_rules(&mut merged.allow, &rule);
    }

    normalize_shell_rules(&mut merged);
    merged
}

fn merge_shell_rule_prefixes(
    base: ShellRulesConfig,
    overlay: ShellRulesConfig,
) -> ShellRulesConfig {
    let mut merged = ShellRulesConfig {
        version: base.version.max(overlay.version),
        // Agent/session overlays only contribute allow/deny prefixes. Their
        // default `ask` mode must not silently erase the global/workspace mode.
        mode: base.mode,
        allow: base.allow,
        deny: base.deny,
    };

    for rule in overlay.allow {
        upsert_shell_rule(&mut merged.allow, &rule);
        prune_opposite_rules(&mut merged.deny, &rule);
    }
    for rule in overlay.deny {
        upsert_shell_rule(&mut merged.deny, &rule);
        prune_opposite_rules(&mut merged.allow, &rule);
    }

    normalize_shell_rules(&mut merged);
    merged
}

fn merge_cli_settings(base: CliSettings, overlay: CliSettings) -> CliSettings {
    CliSettings {
        supplemental_system_prompt: if overlay.supplemental_system_prompt.trim().is_empty() {
            base.supplemental_system_prompt
        } else {
            overlay.supplemental_system_prompt
        },
        close_model_without_confirmation: base.close_model_without_confirmation
            || overlay.close_model_without_confirmation,
    }
}

fn normalize_shell_rules(rules: &mut ShellRulesConfig) {
    rules.allow = normalize_shell_rule_list(std::mem::take(&mut rules.allow));
    rules.deny = normalize_shell_rule_list(std::mem::take(&mut rules.deny));
}

fn normalize_shell_rule_list(items: Vec<String>) -> Vec<String> {
    let mut normalized = Vec::<Vec<String>>::new();
    for item in items {
        let tokens = tokenize_shell_rule(&item);
        if tokens.is_empty() {
            continue;
        }
        if normalized
            .iter()
            .any(|existing| is_prefix_tokens(existing, &tokens))
        {
            continue;
        }
        normalized.retain(|existing| !is_prefix_tokens(&tokens, existing));
        normalized.push(tokens);
    }
    normalized
        .into_iter()
        .map(|tokens| tokens.join(" "))
        .collect()
}

fn upsert_shell_rule(items: &mut Vec<String>, rule: &str) {
    let tokens = tokenize_shell_rule(rule);
    if tokens.is_empty() {
        return;
    }
    let rendered = tokens.join(" ");
    items.retain(|existing| {
        let existing_tokens = tokenize_shell_rule(existing);
        !is_prefix_tokens(&tokens, &existing_tokens)
    });
    if items.iter().any(|existing| existing == &rendered) {
        return;
    }
    items.push(rendered);
}

fn prune_opposite_rules(items: &mut Vec<String>, rule: &str) {
    let rule_tokens = tokenize_shell_rule(rule);
    if rule_tokens.is_empty() {
        return;
    }
    // A higher-precedence rule only deletes lower-precedence opposite entries
    // that it fully covers. This preserves the narrower-vs-broader distinction
    // required by the permission merge examples in the design note.
    items.retain(|existing| {
        let existing_tokens = tokenize_shell_rule(existing);
        !is_prefix_tokens(&rule_tokens, &existing_tokens)
    });
}

fn tokenize_shell_rule(raw: &str) -> Vec<String> {
    raw.split_whitespace()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
        .collect()
}

fn is_prefix_tokens(prefix: &[String], candidate: &[String]) -> bool {
    prefix.len() <= candidate.len()
        && prefix
            .iter()
            .zip(candidate.iter())
            .all(|(left, right)| left == right)
}

pub fn build_agent_system_prompt(config: &SirixConfig, agent: &AgentConfig) -> String {
    let mut sections = Vec::<String>::new();
    if !config.cli.supplemental_system_prompt.trim().is_empty() {
        sections.push(config.cli.supplemental_system_prompt.trim().to_string());
    }
    if !agent.system_prompt.trim().is_empty() {
        sections.push(agent.system_prompt.trim().to_string());
    }

    sections.join("\n\n")
}

fn agent_preview_session_storage_dir(sirix_home: &Path, agent: &AgentConfig) -> PathBuf {
    sirix_home
        .join("runtime")
        .join("prompt-preview")
        .join(agent.id.as_str())
}

fn selected_agent_sub_agents<'a>(
    config: &'a SirixConfig,
    agent: &'a AgentConfig,
) -> Vec<&'a AgentConfig> {
    agent
        .sub_agent_ids
        .iter()
        .filter_map(|id| config.agents.iter().find(|candidate| candidate.id == *id))
        .filter(|candidate| candidate.enabled && is_agent_launchable(config, candidate))
        .collect()
}

fn render_agent_role_description(
    config: &SirixConfig,
    agent: &AgentConfig,
    sub_agents: &[&AgentConfig],
) -> String {
    let mut lines = Vec::<String>::new();
    if agent.description.trim().is_empty() {
        lines.push(format!(
            "Use `{}` when the task should run with this Sirix agent profile.",
            agent.id
        ));
    } else {
        lines.push(format!(
            "Use `{}` for tasks matching this Sirix agent profile: {}",
            agent.id,
            agent.description.trim()
        ));
    }
    lines.push(format!(
        "This Sirix agent uses model `{}` / `{}`.",
        agent.provider_id, agent.model_id
    ));

    let skill_names = config
        .skills
        .iter()
        .filter(|skill| skill.enabled && agent.skill_ids.contains(&skill.id))
        .map(|skill| skill.name.as_str())
        .collect::<Vec<_>>();
    if !skill_names.is_empty() {
        lines.push(format!(
            "Available local skills: {}.",
            skill_names.join(", ")
        ));
    }

    let mcp_names = config
        .mcp_servers
        .iter()
        .filter(|server| server.enabled && agent.mcp_server_ids.contains(&server.id))
        .map(|server| server.name.as_str())
        .collect::<Vec<_>>();
    if !mcp_names.is_empty() {
        lines.push(format!("Available MCP servers: {}.", mcp_names.join(", ")));
    }

    if sub_agents.is_empty() {
        lines.push("This Sirix agent cannot spawn additional Sirix sub-agents.".to_string());
    } else {
        lines.push(format!(
            "This Sirix agent can further delegate to: {}.",
            sub_agents
                .iter()
                .map(|item| format!("`{}`", item.id))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    lines.join("\n")
}

fn build_sirix_skill_config(config: &SirixConfig, agent: &AgentConfig) -> TomlValue {
    // Mirror Codex's `skills.config` shape so prompt injection and explicit skill
    // loading continue to work through the native skills pipeline instead of a
    // Sirix-only prompt shim.
    let config_entries = config
        .skills
        .iter()
        .filter(|skill| skill.enabled)
        .map(|skill| {
            let mut entry = toml::map::Map::<String, TomlValue>::new();
            entry.insert("path".to_string(), TomlValue::String(skill.path.clone()));
            entry.insert(
                "enabled".to_string(),
                TomlValue::Boolean(agent.skill_ids.contains(&skill.id)),
            );
            TomlValue::Table(entry)
        })
        .collect::<Vec<_>>();

    let mut skills = toml::map::Map::<String, TomlValue>::new();
    skills.insert("config".to_string(), TomlValue::Array(config_entries));
    TomlValue::Table(skills)
}

fn build_sirix_agent_role_entries(
    config: &SirixConfig,
    agent: &AgentConfig,
    role_files: &HashMap<String, PathBuf>,
) -> TomlValue {
    // Codex config expects user-defined roles directly under `[agents.<role>]`.
    // It does not accept an intermediate `roles` table in TOML input, even
    // though the runtime stores them under an internal `roles` field after
    // deserialization. Writing the flattened shape here keeps Sirix bridge
    // output compatible with `ConfigToml`.
    let mut roles = toml::map::Map::<String, TomlValue>::new();
    let sub_agents = selected_agent_sub_agents(config, agent);
    for sub_agent in &sub_agents {
        let Some(role_file) = role_files.get(sub_agent.id.as_str()) else {
            continue;
        };

        let nested_sub_agents = selected_agent_sub_agents(config, sub_agent);
        let mut role = toml::map::Map::<String, TomlValue>::new();
        role.insert(
            "description".to_string(),
            TomlValue::String(render_agent_role_description(
                config,
                sub_agent,
                &nested_sub_agents,
            )),
        );
        role.insert(
            "config_file".to_string(),
            TomlValue::String(role_file.display().to_string()),
        );
        role.insert(
            "nickname_candidates".to_string(),
            TomlValue::Array(vec![TomlValue::String(sub_agent.name.clone())]),
        );
        roles.insert(sub_agent.id.clone(), TomlValue::Table(role));
    }
    TomlValue::Table(roles)
}

fn build_sirix_mcp_servers_table(
    config: &SirixConfig,
    agent: &AgentConfig,
) -> anyhow::Result<TomlValue> {
    let mut servers = toml::map::Map::<String, TomlValue>::new();
    for server in config.mcp_servers.iter().filter(|item| item.enabled) {
        let mut value = parse_mcp_config_value(&server.json_config)
            .with_context(|| format!("invalid mcp config for {}", server.id))?;
        let transport = infer_mcp_transport(&value)
            .with_context(|| format!("mcp server {} has unknown transport", server.id))?;
        let transport_allowed = match transport {
            McpTransportKind::Stdio => config.mcp.allow_stdio,
            McpTransportKind::Http => config.mcp.allow_http,
        };
        if let Some(table) = value.as_table_mut() {
            table.insert(
                "enabled".to_string(),
                TomlValue::Boolean(
                    config.mcp.enabled
                        && transport_allowed
                        && agent.mcp_server_ids.contains(&server.id),
                ),
            );
            if !server.enabled_tools.is_empty() {
                table.insert(
                    "enabled_tools".to_string(),
                    TomlValue::Array(
                        server
                            .enabled_tools
                            .iter()
                            .cloned()
                            .map(TomlValue::String)
                            .collect(),
                    ),
                );
            }
            if !server.disabled_tools.is_empty() {
                table.insert(
                    "disabled_tools".to_string(),
                    TomlValue::Array(
                        server
                            .disabled_tools
                            .iter()
                            .cloned()
                            .map(TomlValue::String)
                            .collect(),
                    ),
                );
            }
        }
        servers.insert(server.id.clone(), value);
    }
    Ok(TomlValue::Table(servers))
}

fn role_model_picker_id(
    providers: &[ProviderConfig],
    agent: &AgentConfig,
) -> anyhow::Result<String> {
    let duplicate_model_ids = duplicate_session_text_model_ids(providers);
    let provider = providers
        .iter()
        .find(|item| item.id == agent.provider_id)
        .with_context(|| {
            format!(
                "provider {} not found for role {}",
                agent.provider_id, agent.id
            )
        })?;
    let model = provider
        .models
        .iter()
        .find(|item| item.id == agent.model_id)
        .with_context(|| format!("model {} not found for role {}", agent.model_id, agent.id))?;
    Ok(session_picker_model_id(
        provider,
        model,
        &duplicate_model_ids,
    ))
}

fn build_sirix_role_config_value(
    config: &SirixConfig,
    providers: &[ProviderConfig],
    agent: &AgentConfig,
    workspace_root: &Path,
    role_files: &HashMap<String, PathBuf>,
) -> anyhow::Result<TomlValue> {
    let mut root = toml::map::Map::<String, TomlValue>::new();
    root.insert(
        "developer_instructions".to_string(),
        TomlValue::String(build_agent_system_prompt(config, agent)),
    );
    root.insert(
        "model".to_string(),
        TomlValue::String(role_model_picker_id(providers, agent)?),
    );
    root.insert(
        "sirix_agent_id".to_string(),
        TomlValue::String(agent.id.clone()),
    );
    root.insert(
        "sirix_shell_mode".to_string(),
        TomlValue::String(shell_mode_override_for_agent(
            workspace_root,
            agent,
            config,
        )?),
    );
    root.insert(
        "skills".to_string(),
        build_sirix_skill_config(config, agent),
    );
    root.insert(
        "mcp_servers".to_string(),
        build_sirix_mcp_servers_table(config, agent)?,
    );
    root.insert(
        "agents".to_string(),
        build_sirix_agent_role_entries(config, agent, role_files),
    );
    Ok(TomlValue::Table(root))
}

fn is_windows_reserved_file_stem(stem: &str) -> bool {
    let upper = stem.to_ascii_uppercase();
    matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || upper
            .strip_prefix("COM")
            .or_else(|| upper.strip_prefix("LPT"))
            .map(|suffix| matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"))
            .unwrap_or(false)
}

fn sanitize_agent_id_for_role_file_stem(agent_id: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut stem = String::with_capacity(agent_id.len());
    for &byte in agent_id.as_bytes() {
        match byte {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'_' | b'-' => {
                stem.push(char::from(byte));
            }
            _ => {
                stem.push('~');
                stem.push(char::from(HEX[(byte >> 4) as usize]));
                stem.push(char::from(HEX[(byte & 0x0f) as usize]));
            }
        }
    }
    if stem.is_empty() {
        "agent".to_string()
    } else {
        stem
    }
}

fn role_file_stem_for_agent_id(agent_id: &str, used_stems: &mut HashSet<String>) -> String {
    // Role file names are generated on every launch/preview and must be safe on
    // Windows/macOS/Linux. We percent-escape non [A-Za-z0-9_-] bytes so:
    // 1) path separators like `/` or `\\` cannot escape `role_dir`,
    // 2) Windows-forbidden characters (for example `: * ?`) become valid, and
    // 3) IDs stay deterministic even with non-ASCII bytes.
    let mut stem = sanitize_agent_id_for_role_file_stem(agent_id);
    // Windows reserved basenames (CON/PRN/AUX/NUL/COM1-9/LPT1-9) cannot be used
    // even when an extension is present, so add a marker suffix.
    if is_windows_reserved_file_stem(stem.as_str()) {
        stem.push('~');
    }
    if used_stems.insert(stem.clone()) {
        return stem;
    }

    let base = stem.clone();
    let mut suffix = 2usize;
    loop {
        let candidate = format!("{base}~{suffix}");
        if used_stems.insert(candidate.clone()) {
            return candidate;
        }
        suffix += 1;
    }
}

fn write_sirix_agent_role_files(
    config: &SirixConfig,
    providers: &[ProviderConfig],
    workspace_root: &Path,
    role_dir: &Path,
) -> anyhow::Result<HashMap<String, PathBuf>> {
    fs::create_dir_all(role_dir)
        .with_context(|| format!("failed to create {}", role_dir.display()))?;

    let mut role_files = HashMap::new();
    let mut used_stems = HashSet::new();
    for agent in config
        .agents
        .iter()
        .filter(|item| item.enabled && is_agent_launchable(config, item))
    {
        let role_stem = role_file_stem_for_agent_id(agent.id.as_str(), &mut used_stems);
        role_files.insert(agent.id.clone(), role_dir.join(format!("{role_stem}.toml")));
    }

    for agent in config
        .agents
        .iter()
        .filter(|item| item.enabled && is_agent_launchable(config, item))
    {
        let role_value =
            build_sirix_role_config_value(config, providers, agent, workspace_root, &role_files)?;
        let role_path = role_files
            .get(agent.id.as_str())
            .with_context(|| format!("missing role path for {}", agent.id))?;
        let serialized =
            toml::to_string_pretty(&role_value).context("failed to serialize Sirix role config")?;
        fs::write(role_path, serialized)
            .with_context(|| format!("failed to write {}", role_path.display()))?;
    }

    Ok(role_files)
}

pub async fn build_agent_system_prompt_preview(
    config: &SirixConfig,
    agent: &AgentConfig,
    sirix_home: &Path,
    workspace_root: Option<&Path>,
) -> anyhow::Result<serde_json::Value> {
    let workspace_root = workspace_root
        .map(Path::to_path_buf)
        .unwrap_or(std::env::current_dir().context("failed to resolve current_dir for preview")?);
    let provider = config
        .providers
        .iter()
        .find(|item| item.id == agent.provider_id && item.enabled)
        .cloned()
        .with_context(|| {
            format!(
                "provider {} not found for agent {}",
                agent.provider_id, agent.id
            )
        })?;
    let model = provider
        .models
        .iter()
        .find(|item| item.id == agent.model_id && item.enabled)
        .cloned()
        .with_context(|| format!("model {} not found for agent {}", agent.model_id, agent.id))?;
    let preview_storage_dir = agent_preview_session_storage_dir(sirix_home, agent);
    fs::create_dir_all(&preview_storage_dir)
        .with_context(|| format!("failed to create {}", preview_storage_dir.display()))?;

    let launch = AiLaunchConfig {
        effective_config: config.clone(),
        agent: agent.clone(),
        provider,
        model,
        session_providers: config.providers.clone(),
        codex_home: sirix_home.join("runtime").join("prompt-preview"),
        session_storage_dir: preview_storage_dir.clone(),
        workspace_root: workspace_root.clone(),
        workspace_source: None,
    };
    let bridge_config = build_codex_bridge_toml(
        config.clone(),
        &launch,
        workspace_root.as_path(),
        /*local_ws_port*/ 0,
        Uuid::nil(),
    )?;
    let cli_overrides = bridge_config
        .into_iter()
        .collect::<Vec<(String, TomlValue)>>();
    let codex_config = Config::load_default_with_cli_overrides_for_codex_home(
        launch.codex_home.clone(),
        cli_overrides,
    )
    .context("failed to build Codex preview config")?;

    let runtime_path = preview_storage_dir.join(SIRIX_AGENT_RUNTIME_FILE_NAME);
    let runtime = SessionAgentRuntimeConfig {
        agent_id: agent.id.clone(),
        shell_mode: agent.approval_mode.clone(),
        builtin_tool_ids: agent.builtin_tool_ids.clone(),
    };
    let serialized_runtime =
        serde_json::to_string_pretty(&runtime).context("failed to serialize preview runtime")?;
    fs::write(&runtime_path, serialized_runtime)
        .with_context(|| format!("failed to write {}", runtime_path.display()))?;

    let _guard = PROMPT_PREVIEW_RUNTIME_ENV_LOCK.lock().await;
    let previous_runtime_env = env::var(SIRIX_AGENT_RUNTIME_PATH_ENV).ok();
    env::set_var(SIRIX_AGENT_RUNTIME_PATH_ENV, runtime_path.as_os_str());
    // Preview the actual Responses API request shape generated by the embedded
    // Codex runtime. We intentionally pass an empty user-input list here so the
    // preview focuses on static agent context (system prompt, developer blocks,
    // tools, skills, MCP wiring) instead of echoing a transient conversation.
    let request_result = build_responses_request_preview(codex_config, Vec::new()).await;
    match previous_runtime_env {
        Some(previous) => env::set_var(SIRIX_AGENT_RUNTIME_PATH_ENV, previous),
        None => env::remove_var(SIRIX_AGENT_RUNTIME_PATH_ENV),
    }
    let request = request_result.context("failed to build Codex request preview")?;

    serde_json::to_value(request).context("failed to serialize request preview")
}

fn render_exec_policy_prefix_rule(
    raw_prefix: &str,
    decision: &str,
    justification: Option<&str>,
) -> Option<String> {
    let tokens = tokenize_shell_rule(raw_prefix);
    if tokens.is_empty() {
        return None;
    }
    let pattern = serde_json::to_string(&tokens).ok()?;
    let mut rule = format!(r#"prefix_rule(pattern={pattern}, decision="{decision}""#);
    if let Some(justification) = justification.filter(|value| !value.trim().is_empty()) {
        rule.push_str(&format!(
            r#", justification={}"#,
            serde_json::to_string(justification).ok()?
        ));
    }
    rule.push(')');
    Some(rule)
}

pub fn builtin_tool_catalog() -> Vec<&'static str> {
    vec![
        "shell",
        "shell_command",
        "exec_command",
        "write_stdin",
        "apply_patch",
        "update_plan",
        "request_user_input",
        "request_permissions",
        "view_image",
        "web_search",
        "image_generation",
        "code_mode",
        "js_repl",
        "js_repl_reset",
        "list_dir",
        "list_mcp_resources",
        "list_mcp_resource_templates",
        "read_mcp_resource",
        "spawn_agent",
        "send_message",
        "followup_task",
        "wait_agent",
        "close_agent",
        "list_agents",
    ]
}

fn default_true() -> bool {
    true
}

fn default_config_version() -> u32 {
    1
}

fn default_shell_rules_version() -> u32 {
    1
}

fn default_shell_rules_mode() -> ApprovalMode {
    ApprovalMode::Ask
}

fn default_shell_rules_deny_list() -> Vec<String> {
    vec![
        "rm -rf".to_string(),
        "sudo rm".to_string(),
        "mkfs".to_string(),
    ]
}

fn default_builtin_tool_ids() -> Vec<String> {
    builtin_tool_catalog()
        .into_iter()
        .map(ToString::to_string)
        .collect()
}

fn sirix_home_dir() -> anyhow::Result<PathBuf> {
    if let Ok(explicit) = env::var("SIRIX_HOME") {
        if !explicit.trim().is_empty() {
            return Ok(PathBuf::from(explicit));
        }
    }

    // Follow Codex's source behavior and ask the platform for the user's home
    // directory first. That keeps `~/.sirix` stable across macOS/Linux/Windows
    // instead of depending on whichever shell variables happen to be present.
    if let Some(home) = dirs::home_dir() {
        return Ok(home.join(".sirix"));
    }

    let home = env::var("HOME")
        .or_else(|_| env::var("USERPROFILE"))
        .or_else(|_| match (env::var("HOMEDRIVE"), env::var("HOMEPATH")) {
            (Ok(drive), Ok(path)) => Ok(format!("{drive}{path}")),
            _ => Err(env::VarError::NotPresent),
        })
        .context("failed to resolve user home dir for ~/.sirix")?;
    Ok(PathBuf::from(home).join(".sirix"))
}

fn migrate_legacy_codex_home(sirix_home: &Path) -> anyhow::Result<()> {
    let home = sirix_home
        .parent()
        .context("failed to resolve ~/.sirix parent")?;
    let legacy = home.join(".codex");
    if !legacy.is_dir() || sirix_home.exists() {
        return Ok(());
    }

    copy_dir_recursive(&legacy, sirix_home).with_context(|| {
        format!(
            "failed to migrate {} -> {}",
            legacy.display(),
            sirix_home.display()
        )
    })?;
    Ok(())
}

fn copy_dir_recursive(from: &Path, to: &Path) -> anyhow::Result<()> {
    fs::create_dir_all(to).with_context(|| format!("failed to create {}", to.display()))?;
    for entry in fs::read_dir(from).with_context(|| format!("failed to read {}", from.display()))? {
        let entry = entry?;
        let path = entry.path();
        let target = to.join(entry.file_name());
        let metadata = entry.metadata()?;
        if metadata.is_dir() {
            copy_dir_recursive(&path, &target)?;
            continue;
        }
        if metadata.is_file() {
            fs::copy(&path, &target).with_context(|| {
                format!("failed to copy {} -> {}", path.display(), target.display())
            })?;
        }
    }
    Ok(())
}

fn merge_projects_into_config_path(
    path: &Path,
    projects: &toml::map::Map<String, TomlValue>,
) -> anyhow::Result<()> {
    let mut root = if path.is_file() {
        let raw = fs::read_to_string(path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        parse_toml_document_value(&raw)
            .with_context(|| format!("failed to parse {}", path.display()))?
    } else {
        TomlValue::Table(toml::map::Map::new())
    };

    if !root.is_table() {
        root = TomlValue::Table(toml::map::Map::new());
    }

    let root_table = root
        .as_table_mut()
        .context("shared Sirix config root must be a table")?;
    let projects_value = root_table
        .entry("projects".to_string())
        .or_insert_with(|| TomlValue::Table(toml::map::Map::new()));
    if !projects_value.is_table() {
        *projects_value = TomlValue::Table(toml::map::Map::new());
    }
    let projects_table = projects_value
        .as_table_mut()
        .context("shared Sirix projects value must be a table")?;

    let mut changed = false;
    for (project_key, project_value) in projects {
        let Some(project_table) = project_value.as_table() else {
            continue;
        };
        let Some(trust_level) = project_table.get("trust_level").and_then(TomlValue::as_str) else {
            continue;
        };

        let mut merged_project = projects_table
            .get(project_key)
            .and_then(TomlValue::as_table)
            .cloned()
            .unwrap_or_default();
        let existing_trust = merged_project
            .get("trust_level")
            .and_then(TomlValue::as_str)
            .unwrap_or_default();
        if existing_trust == trust_level {
            continue;
        }
        merged_project.insert(
            "trust_level".to_string(),
            TomlValue::String(trust_level.to_string()),
        );
        projects_table.insert(project_key.clone(), TomlValue::Table(merged_project));
        changed = true;
    }

    if !changed && path.is_file() {
        return Ok(());
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let serialized =
        toml::to_string_pretty(&root).context("failed to serialize shared Sirix config")?;
    fs::write(path, serialized).with_context(|| format!("failed to write {}", path.display()))
}

fn append_file_contents(from: &Path, to: &Path) -> anyhow::Result<()> {
    let body = fs::read(from).with_context(|| format!("failed to read {}", from.display()))?;
    if body.is_empty() {
        return Ok(());
    }

    let mut handle = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(to)
        .with_context(|| format!("failed to open {}", to.display()))?;
    use std::io::Write as _;
    handle
        .write_all(&body)
        .with_context(|| format!("failed to append {}", to.display()))
}

fn render_cli_overrides(root: &toml::map::Map<String, TomlValue>) -> anyhow::Result<Vec<String>> {
    let mut overrides = Vec::with_capacity(root.len());
    for (key, value) in root {
        overrides.push(format!("{key}={}", render_toml_value_inline(value)?));
    }
    Ok(overrides)
}

fn render_toml_value_inline(value: &TomlValue) -> anyhow::Result<String> {
    match value {
        TomlValue::String(_)
        | TomlValue::Integer(_)
        | TomlValue::Float(_)
        | TomlValue::Boolean(_)
        | TomlValue::Datetime(_) => Ok(value.to_string()),
        TomlValue::Array(items) => {
            let rendered = items
                .iter()
                .map(render_toml_value_inline)
                .collect::<anyhow::Result<Vec<_>>>()?;
            Ok(format!("[{}]", rendered.join(", ")))
        }
        TomlValue::Table(table) => {
            let rendered = table
                .iter()
                .map(|(key, value)| {
                    Ok(format!(
                        "{} = {}",
                        render_toml_key(key),
                        render_toml_value_inline(value)?
                    ))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            Ok(format!("{{{}}}", rendered.join(", ")))
        }
    }
}

fn render_toml_key(key: &str) -> String {
    if key
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-')
    {
        key.to_string()
    } else {
        TomlValue::String(key.to_string()).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unique_session_storage_dir(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("sirix-{label}-{}", Uuid::new_v4()))
    }

    fn test_agent(provider_id: &str, model_id: &str, prompt: &str) -> AgentConfig {
        AgentConfig {
            id: "agent".to_string(),
            name: "Agent".to_string(),
            description: "Test agent".to_string(),
            provider_id: provider_id.to_string(),
            model_id: model_id.to_string(),
            fallback_provider_id: String::new(),
            fallback_model_id: String::new(),
            system_prompt: prompt.to_string(),
            approval_mode: ApprovalMode::Ask,
            shell_rules: ShellRulesConfig::default(),
            tool_rules: ToolRulesConfig::default(),
            builtin_tool_ids: default_builtin_tool_ids(),
            skill_ids: Vec::new(),
            mcp_server_ids: Vec::new(),
            sub_agent_ids: Vec::new(),
            enabled: true,
            legacy_builtin_tools_enabled: None,
            legacy_enabled_skill_ids: Vec::new(),
            legacy_disabled_skill_ids: Vec::new(),
            legacy_enabled_mcp_server_ids: Vec::new(),
            legacy_disabled_mcp_server_ids: Vec::new(),
            legacy_capability_rules: Vec::new(),
        }
    }

    #[test]
    fn role_file_stem_escapes_path_and_windows_forbidden_characters() {
        let mut used = HashSet::new();
        let stem = role_file_stem_for_agent_id("../agent\\name:*?\"<>|", &mut used);
        assert_eq!(stem, "~2e~2e~2fagent~5cname~3a~2a~3f~22~3c~3e~7c");
        assert!(!stem.contains('/'));
        assert!(!stem.contains('\\'));
    }

    #[test]
    fn write_sirix_agent_role_files_avoids_windows_reserved_basename() {
        let role_dir = unique_session_storage_dir("reserved-role-stem");
        let mut config = SirixConfig::default();
        let mut agent = test_agent(DEFAULT_PROVIDER_ID, DEFAULT_MODEL_ID, "reserved");
        agent.id = "CON".to_string();
        config.agents = vec![agent.clone()];

        let workspace_root = PathBuf::from("/tmp/workspace");
        let role_files = write_sirix_agent_role_files(
            &config,
            &config.providers,
            workspace_root.as_path(),
            &role_dir,
        )
        .expect("role files should be generated");
        let role_path = role_files
            .get(agent.id.as_str())
            .expect("role path should exist for CON agent");

        assert!(role_path.starts_with(&role_dir));
        assert_eq!(role_path.parent(), Some(role_dir.as_path()));
        assert_eq!(
            role_path.extension().and_then(|value| value.to_str()),
            Some("toml")
        );
        assert_eq!(
            role_path.file_name().and_then(|value| value.to_str()),
            Some("CON~.toml")
        );
        assert!(role_path.is_file());
    }

    #[test]
    fn normalized_config_migrates_legacy_default_agent_to_builtin_codex() {
        let mut config = SirixConfig::default();
        config.agents = vec![AgentConfig {
            id: LEGACY_DEFAULT_AGENT_ID.to_string(),
            name: "Default Agent".to_string(),
            description: "Default Sirix coding agent.".to_string(),
            provider_id: DEFAULT_PROVIDER_ID.to_string(),
            model_id: DEFAULT_MODEL_ID.to_string(),
            fallback_provider_id: String::new(),
            fallback_model_id: String::new(),
            system_prompt: "legacy override".to_string(),
            approval_mode: ApprovalMode::Ask,
            shell_rules: ShellRulesConfig::default(),
            tool_rules: ToolRulesConfig::default(),
            builtin_tool_ids: vec!["shell".to_string()],
            skill_ids: vec!["skill-a".to_string()],
            mcp_server_ids: vec!["mcp-a".to_string()],
            sub_agent_ids: vec!["reviewer".to_string()],
            enabled: false,
            legacy_builtin_tools_enabled: None,
            legacy_enabled_skill_ids: Vec::new(),
            legacy_disabled_skill_ids: Vec::new(),
            legacy_enabled_mcp_server_ids: Vec::new(),
            legacy_disabled_mcp_server_ids: Vec::new(),
            legacy_capability_rules: Vec::new(),
        }];

        let normalized = normalized_sirix_config(&config);
        assert_eq!(normalized.agents.len(), 1);
        let agent = &normalized.agents[0];
        assert_eq!(agent.id, DEFAULT_AGENT_ID);
        assert_eq!(agent.name, DEFAULT_AGENT_NAME);
        assert_eq!(agent.description, DEFAULT_AGENT_DESCRIPTION);
        assert_eq!(agent.provider_id, DEFAULT_PROVIDER_ID);
        assert_eq!(agent.model_id, DEFAULT_MODEL_ID);
        assert_eq!(agent.skill_ids, vec!["skill-a".to_string()]);
        assert_eq!(agent.mcp_server_ids, vec!["mcp-a".to_string()]);
        assert_eq!(agent.sub_agent_ids, vec!["reviewer".to_string()]);
        assert_eq!(agent.system_prompt, "");
        assert_eq!(agent.builtin_tool_ids, default_builtin_tool_ids());
        assert!(agent.enabled);
    }

    #[test]
    fn agent_and_session_shell_prefixes_override_broader_defaults_without_resetting_mode() {
        let base = ShellRulesConfig {
            version: 1,
            mode: ApprovalMode::Allow,
            allow: vec!["git".to_string()],
            deny: vec!["git push".to_string(), "rm -rf".to_string()],
        };
        let agent = ShellRulesConfig {
            version: 1,
            mode: ApprovalMode::Ask,
            allow: vec!["git push".to_string()],
            deny: vec!["cargo test".to_string()],
        };
        let session = ShellRulesConfig {
            version: 1,
            mode: ApprovalMode::Ask,
            allow: vec!["cargo test".to_string()],
            deny: vec!["git status".to_string()],
        };

        let merged = merge_shell_rule_prefixes(merge_shell_rule_prefixes(base, agent), session);

        assert_eq!(merged.mode, ApprovalMode::Allow);
        assert!(merged.allow.contains(&"git".to_string()));
        assert!(
            !merged.deny.contains(&"git push".to_string()),
            "agent allow should remove the broader default deny for git push"
        );
        assert!(merged.allow.contains(&"cargo test".to_string()));
        assert!(!merged.deny.contains(&"git push".to_string()));
        assert!(!merged.deny.contains(&"cargo test".to_string()));
        assert!(merged.deny.contains(&"git status".to_string()));
        assert!(merged.deny.contains(&"rm -rf".to_string()));
    }

    #[test]
    fn bridge_injects_sirix_sub_agents_as_codex_roles() {
        let session_dir = unique_session_storage_dir("roles");
        let codex_home = unique_session_storage_dir("roles-codex-home");
        let skill = SkillConfig {
            id: "review-skill".to_string(),
            name: "Review Skill".to_string(),
            path: "/tmp/review-skill".to_string(),
            enabled: true,
            allow_outside_sandbox: false,
        };
        let mcp_server = McpServerConfig {
            id: "docs".to_string(),
            name: "Docs".to_string(),
            enabled: true,
            approval_mode: ApprovalMode::Ask,
            enabled_tools: vec!["search".to_string()],
            disabled_tools: Vec::new(),
            json_config: r#"
command = "docs-mcp"
args = ["serve"]
"#
            .to_string(),
        };
        let reviewer = AgentConfig {
            id: "reviewer".to_string(),
            name: "Reviewer".to_string(),
            description: "Review-focused Sirix agent.".to_string(),
            provider_id: DEFAULT_PROVIDER_ID.to_string(),
            model_id: DEFAULT_MODEL_ID.to_string(),
            fallback_provider_id: String::new(),
            fallback_model_id: String::new(),
            system_prompt: "Review carefully".to_string(),
            approval_mode: ApprovalMode::Ask,
            shell_rules: ShellRulesConfig::default(),
            tool_rules: ToolRulesConfig::default(),
            builtin_tool_ids: default_builtin_tool_ids(),
            skill_ids: vec![skill.id.clone()],
            mcp_server_ids: vec![mcp_server.id.clone()],
            sub_agent_ids: Vec::new(),
            enabled: true,
            legacy_builtin_tools_enabled: None,
            legacy_enabled_skill_ids: Vec::new(),
            legacy_disabled_skill_ids: Vec::new(),
            legacy_enabled_mcp_server_ids: Vec::new(),
            legacy_disabled_mcp_server_ids: Vec::new(),
            legacy_capability_rules: Vec::new(),
        };
        let root_agent = AgentConfig {
            id: DEFAULT_AGENT_ID.to_string(),
            name: DEFAULT_AGENT_NAME.to_string(),
            description: DEFAULT_AGENT_DESCRIPTION.to_string(),
            provider_id: DEFAULT_PROVIDER_ID.to_string(),
            model_id: DEFAULT_MODEL_ID.to_string(),
            fallback_provider_id: String::new(),
            fallback_model_id: String::new(),
            system_prompt: String::new(),
            approval_mode: ApprovalMode::Ask,
            shell_rules: ShellRulesConfig::default(),
            tool_rules: ToolRulesConfig::default(),
            builtin_tool_ids: default_builtin_tool_ids(),
            skill_ids: Vec::new(),
            mcp_server_ids: Vec::new(),
            sub_agent_ids: vec![reviewer.id.clone()],
            enabled: true,
            legacy_builtin_tools_enabled: None,
            legacy_enabled_skill_ids: Vec::new(),
            legacy_disabled_skill_ids: Vec::new(),
            legacy_enabled_mcp_server_ids: Vec::new(),
            legacy_disabled_mcp_server_ids: Vec::new(),
            legacy_capability_rules: Vec::new(),
        };

        let config = SirixConfig {
            skills: vec![skill.clone()],
            mcp_servers: vec![mcp_server.clone()],
            agents: vec![root_agent.clone(), reviewer.clone()],
            ..SirixConfig::default()
        };
        let provider = config.providers[0].clone();
        let launch = AiLaunchConfig {
            effective_config: config.clone(),
            agent: root_agent,
            provider: provider.clone(),
            model: provider.models[0].clone(),
            session_providers: vec![provider],
            codex_home: codex_home.clone(),
            session_storage_dir: session_dir.clone(),
            workspace_root: PathBuf::from("/tmp/workspace"),
            workspace_source: None,
        };

        let bridge = build_codex_bridge_toml(
            config,
            &launch,
            Path::new("/tmp/workspace"),
            9701,
            Uuid::nil(),
        )
        .expect("bridge config should build");

        let role = bridge
            .get("agents")
            .and_then(TomlValue::as_table)
            .and_then(|agents| agents.get("reviewer"))
            .and_then(TomlValue::as_table)
            .expect("reviewer role should exist");
        let description = role
            .get("description")
            .and_then(TomlValue::as_str)
            .expect("role description should exist");
        assert!(description.contains("Review-focused Sirix agent."));
        assert!(description.contains("Review Skill"));
        assert!(description.contains("Docs"));

        let role_path = role
            .get("config_file")
            .and_then(TomlValue::as_str)
            .map(PathBuf::from)
            .expect("role config file should exist");
        let body = fs::read_to_string(&role_path).expect("role config should be readable");
        assert!(body.contains("developer_instructions = \"Review carefully\""));
        assert!(body.contains("[mcp_servers.docs]"));
        assert!(body.contains("[[skills.config]]"));

        let cli_overrides = bridge.into_iter().collect::<Vec<(String, TomlValue)>>();
        let loaded =
            Config::load_default_with_cli_overrides_for_codex_home(codex_home, cli_overrides)
                .expect("bridge config should deserialize into Codex config");
        assert!(loaded.agent_roles.contains_key("reviewer"));
    }

    #[test]
    fn bridge_targets_sirix_session_proxy_provider() {
        let ai_session_id =
            Uuid::parse_str("11111111-2222-3333-4444-555555555555").expect("uuid should parse");
        let provider = ProviderConfig {
            id: "glm".to_string(),
            name: "GLM".to_string(),
            kind: ProviderKind::OpenAiCompatible,
            default_context_window: Some(128_000),
            base_url: "https://open.bigmodel.cn/api/coding/paas/v4".to_string(),
            api_key_env: "GLM_API_KEY".to_string(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![ModelConfig {
                id: "glm-5-turbo".to_string(),
                display_name: "GLM 5 Turbo".to_string(),
                model_kind: ModelKind::Text,
                context_window: None,
                supports_images: false,
                enabled: true,
            }],
        };
        let launch = AiLaunchConfig {
            effective_config: SirixConfig::default(),
            agent: test_agent("glm", "glm-5-turbo", "system prompt"),
            provider: provider.clone(),
            model: provider.models[0].clone(),
            session_providers: vec![provider],
            codex_home: PathBuf::from("/tmp/.sirix"),
            session_storage_dir: unique_session_storage_dir("proxy"),
            workspace_root: PathBuf::from("/tmp/workspace"),
            workspace_source: None,
        };

        let config = build_codex_bridge_toml(
            SirixConfig::default(),
            &launch,
            Path::new("/tmp/workspace"),
            9701,
            ai_session_id,
        )
        .expect("bridge config should build");

        let providers = config
            .get("model_providers")
            .and_then(TomlValue::as_table)
            .expect("model_providers should exist");
        let provider = providers
            .get(SIRIX_SESSION_PROXY_PROVIDER_ID)
            .and_then(TomlValue::as_table)
            .expect("session proxy provider should exist");

        assert_eq!(
            provider.get("base_url").and_then(TomlValue::as_str),
            Some(
                "http://127.0.0.1:9701/ai/sessions/11111111-2222-3333-4444-555555555555/provider/v1"
            )
        );
        assert_eq!(
            provider.get("wire_api").and_then(TomlValue::as_str),
            Some("responses")
        );
    }

    #[test]
    fn bridge_models_use_provider_scoped_alias_for_duplicate_slugs() {
        let active = ProviderConfig {
            id: "openai-codex-oauth".to_string(),
            name: "OpenAI Codex OAuth".to_string(),
            kind: ProviderKind::OpenAiCodexOauth,
            default_context_window: Some(400_000),
            base_url: "https://chatgpt.com/backend-api/codex".to_string(),
            api_key_env: String::new(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![ModelConfig {
                id: "gpt-5.2".to_string(),
                display_name: "gpt-5.2".to_string(),
                model_kind: ModelKind::Text,
                context_window: Some(272_000),
                supports_images: false,
                enabled: true,
            }],
        };
        let secondary = ProviderConfig {
            id: "openai-codex-oauth-gemini".to_string(),
            name: "OpenAI Codex OAuth Gemini".to_string(),
            kind: ProviderKind::OpenAiCodexOauth,
            default_context_window: Some(400_000),
            base_url: "https://chatgpt.com/backend-api/codex".to_string(),
            api_key_env: String::new(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![ModelConfig {
                id: "gpt-5.2".to_string(),
                display_name: "gpt-5.2".to_string(),
                model_kind: ModelKind::Text,
                context_window: Some(272_000),
                supports_images: false,
                enabled: true,
            }],
        };

        let bridge_models = build_bridge_models_for_session(
            &[secondary.clone(), active.clone()],
            active.id.as_str(),
            "gpt-5.2",
        );

        assert_eq!(bridge_models.len(), 2);
        assert_eq!(
            bridge_models[0].get("model").and_then(TomlValue::as_str),
            Some("gpt-5.2 @ openai-codex-oauth")
        );
        assert_eq!(
            bridge_models[0]
                .get("is_default")
                .and_then(TomlValue::as_bool),
            Some(true)
        );
        assert_eq!(
            bridge_models[1].get("model").and_then(TomlValue::as_str),
            Some("gpt-5.2 @ openai-codex-oauth-gemini")
        );

        let providers = [secondary, active];
        let resolved =
            resolve_session_picker_model(&providers, "gpt-5.2 @ openai-codex-oauth-gemini")
                .expect("duplicate alias should resolve back to provider-scoped model");
        assert_eq!(resolved.0.id, "openai-codex-oauth-gemini");
        assert_eq!(resolved.1.id, "gpt-5.2");
    }

    #[test]
    fn bridge_writes_cli_close_toggle_and_active_provider_models() {
        let ai_session_id =
            Uuid::parse_str("11111111-2222-3333-4444-555555555555").expect("uuid should parse");
        let provider = ProviderConfig {
            id: "openai".to_string(),
            name: "OpenAI".to_string(),
            kind: ProviderKind::OpenAiResponses,
            default_context_window: Some(200_000),
            base_url: "https://api.openai.com/v1".to_string(),
            api_key_env: "OPENAI_API_KEY".to_string(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![
                ModelConfig {
                    id: "gpt-5".to_string(),
                    display_name: "GPT-5".to_string(),
                    model_kind: ModelKind::Text,
                    context_window: None,
                    supports_images: true,
                    enabled: true,
                },
                ModelConfig {
                    id: "tts-1".to_string(),
                    display_name: "TTS".to_string(),
                    model_kind: ModelKind::Tts,
                    context_window: None,
                    supports_images: false,
                    enabled: true,
                },
                ModelConfig {
                    id: "gpt-disabled".to_string(),
                    display_name: "Disabled".to_string(),
                    model_kind: ModelKind::Text,
                    context_window: Some(128_000),
                    supports_images: false,
                    enabled: false,
                },
            ],
        };
        let launch = AiLaunchConfig {
            effective_config: SirixConfig::default(),
            agent: test_agent(provider.id.as_str(), "gpt-5", ""),
            provider: provider.clone(),
            model: provider.models[0].clone(),
            session_providers: vec![provider.clone()],
            codex_home: PathBuf::from("/tmp/.sirix"),
            session_storage_dir: unique_session_storage_dir("close-toggle"),
            workspace_root: PathBuf::from("/tmp/workspace"),
            workspace_source: None,
        };
        let mut global = SirixConfig::default();
        global.cli.close_model_without_confirmation = true;
        global.providers = vec![provider];

        let config = build_codex_bridge_toml(
            global,
            &launch,
            Path::new("/tmp/workspace"),
            9701,
            ai_session_id,
        )
        .expect("bridge config should build");

        assert_eq!(
            config
                .get("close_model_without_confirmation")
                .and_then(TomlValue::as_bool),
            Some(true)
        );

        let models = config
            .get("models")
            .and_then(TomlValue::as_array)
            .expect("bridge models should exist");
        assert_eq!(
            models.len(),
            1,
            "only enabled text models should be exported"
        );
        let model = models[0]
            .as_table()
            .expect("bridge model should be a table");
        assert_eq!(
            model.get("model").and_then(TomlValue::as_str),
            Some("gpt-5")
        );
        assert_eq!(
            model.get("show_in_picker").and_then(TomlValue::as_bool),
            Some(true)
        );
        assert_eq!(
            model.get("is_default").and_then(TomlValue::as_bool),
            Some(true)
        );
    }

    #[test]
    fn bridge_exports_enabled_text_models_across_session_providers() {
        let ai_session_id =
            Uuid::parse_str("11111111-2222-3333-4444-555555555555").expect("uuid should parse");
        let active_provider = ProviderConfig {
            id: "glm".to_string(),
            name: "GLM".to_string(),
            kind: ProviderKind::OpenAiCompatible,
            default_context_window: Some(128_000),
            base_url: "https://example.com/v1".to_string(),
            api_key_env: String::new(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![ModelConfig {
                id: "glm-5".to_string(),
                display_name: "GLM 5".to_string(),
                model_kind: ModelKind::Text,
                context_window: None,
                supports_images: false,
                enabled: true,
            }],
        };
        let openai_provider = ProviderConfig {
            id: "openai".to_string(),
            name: "OpenAI".to_string(),
            kind: ProviderKind::OpenAiResponses,
            default_context_window: Some(200_000),
            base_url: "https://api.openai.com/v1".to_string(),
            api_key_env: String::new(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![
                ModelConfig {
                    id: "gpt-5".to_string(),
                    display_name: "GPT-5".to_string(),
                    model_kind: ModelKind::Text,
                    context_window: Some(400_000),
                    supports_images: true,
                    enabled: true,
                },
                ModelConfig {
                    id: "glm-5".to_string(),
                    display_name: "Duplicate GLM".to_string(),
                    model_kind: ModelKind::Text,
                    context_window: Some(128_000),
                    supports_images: true,
                    enabled: true,
                },
            ],
        };
        let launch = AiLaunchConfig {
            effective_config: SirixConfig::default(),
            agent: test_agent(active_provider.id.as_str(), "glm-5", ""),
            provider: active_provider.clone(),
            model: active_provider.models[0].clone(),
            session_providers: vec![openai_provider, active_provider.clone()],
            codex_home: PathBuf::from("/tmp/.sirix"),
            session_storage_dir: unique_session_storage_dir("providers"),
            workspace_root: PathBuf::from("/tmp/workspace"),
            workspace_source: None,
        };

        let config = build_codex_bridge_toml(
            SirixConfig::default(),
            &launch,
            Path::new("/tmp/workspace"),
            9701,
            ai_session_id,
        )
        .expect("bridge config should build");

        let models = config
            .get("models")
            .and_then(TomlValue::as_array)
            .expect("bridge models should exist");
        assert_eq!(
            models.len(),
            2,
            "expected unique text models from both providers"
        );
        assert_eq!(
            models[0]
                .as_table()
                .and_then(|item| item.get("model"))
                .and_then(TomlValue::as_str),
            Some("glm-5"),
            "active-provider duplicate should stay first in the picker catalog"
        );
        assert_eq!(
            models[1]
                .as_table()
                .and_then(|item| item.get("model"))
                .and_then(TomlValue::as_str),
            Some("gpt-5")
        );
    }

    #[test]
    fn parses_legacy_codex_global_config() {
        let raw = r#"
model = "gpt-5.4"
model_provider = "crs"
model_context_window = 400000
instructions = "legacy prompt"
close_model_without_confirmation = true

[model_providers.crs]
name = "CRS"
base_url = "http://127.0.0.1:8001/openai"
env_key = "OPENAI_API_KEY"
wire_api = "responses"

[mcp_servers.task_completion_notification]
command = "npx"
args = ["-y", "notify-mcp"]

[skills]
config = [
  { path = "/tmp/demo-skill", enabled = true }
]
"#;

        let parsed = parse_legacy_codex_config(raw).expect("legacy config should parse");

        assert_eq!(parsed.cli.supplemental_system_prompt, "legacy prompt");
        assert!(parsed.cli.close_model_without_confirmation);
        assert_eq!(parsed.providers.len(), 1);
        assert_eq!(parsed.providers[0].id, "crs");
        assert_eq!(parsed.providers[0].kind, ProviderKind::OpenAiResponses);
        assert_eq!(parsed.providers[0].models[0].id, "gpt-5.4");
        assert_eq!(parsed.providers[0].default_context_window, Some(400000));
        assert_eq!(parsed.providers[0].models[0].context_window, None);
        assert_eq!(parsed.agents.len(), 1);
        assert_eq!(parsed.agents[0].provider_id, "crs");
        assert_eq!(parsed.agents[0].model_id, "gpt-5.4");
        assert_eq!(parsed.mcp_servers.len(), 1);
        assert_eq!(parsed.mcp_servers[0].id, "task_completion_notification");
        assert!(parsed.mcp_servers[0]
            .json_config
            .contains("command = \"npx\""));
        assert_eq!(parsed.skills.len(), 1);
        assert_eq!(parsed.skills[0].path, "/tmp/demo-skill");
    }

    #[test]
    fn legacy_mcp_only_config_is_not_detected_as_legacy() {
        let raw = r#"
[mcp_servers]
value = "unexpected"
"#;

        let value = toml::from_str::<TomlValue>(raw).expect("config should be valid toml");
        let table = value.as_table().expect("config root should be table");

        assert!(!looks_like_legacy_codex_config(table));
    }

    #[test]
    fn legacy_model_only_config_is_still_detected() {
        let raw = r#"
model = "gpt-5.4"
"#;

        let value = toml::from_str::<TomlValue>(raw).expect("config should be valid toml");
        let table = value.as_table().expect("config root should be table");

        assert!(looks_like_legacy_codex_config(table));
    }

    #[test]
    fn workspace_cli_close_toggle_can_override_global_true_with_false() {
        let root = env::temp_dir().join(format!(
            "sirix-config-workspace-override-{}",
            Uuid::new_v4()
        ));
        let sirix_home = root.join("home");
        let workspace_dir = root.join("workspace");
        let workspace_config_dir = workspace_dir.join(".sirix");
        fs::create_dir_all(&workspace_config_dir).expect("workspace config dir should exist");

        let store = SirixConfigStore {
            sirix_home: sirix_home.clone(),
            config_path: sirix_home.join("config.toml"),
        };

        let mut global = SirixConfig::default();
        global.cli.close_model_without_confirmation = true;
        store
            .save_global(&global)
            .expect("global config should be saved");

        fs::write(
            workspace_config_dir.join("config.toml"),
            "[cli]\nclose_model_without_confirmation = false\n",
        )
        .expect("workspace config should be written");

        let effective = store
            .effective_for_workspace(workspace_dir.to_str())
            .expect("effective config should load");

        assert!(
            !effective.config.cli.close_model_without_confirmation,
            "workspace config should be able to disable the global close shortcut override"
        );

        fs::remove_dir_all(&root).expect("temp config tree should be cleaned up");
    }

    #[test]
    fn model_context_window_falls_back_to_provider_default() {
        let provider = ProviderConfig {
            id: "openai".to_string(),
            name: "OpenAI".to_string(),
            kind: ProviderKind::OpenAiResponses,
            default_context_window: Some(222_000),
            base_url: "https://api.openai.com/v1".to_string(),
            api_key_env: String::new(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![ModelConfig {
                id: "gpt-5".to_string(),
                display_name: "GPT-5".to_string(),
                model_kind: ModelKind::Text,
                context_window: None,
                supports_images: true,
                enabled: true,
            }],
        };

        assert_eq!(
            effective_model_context_window(&provider, &provider.models[0]),
            222_000
        );
    }

    #[test]
    fn cli_overrides_render_inline_tables_for_bridge_config() {
        let root = env::temp_dir().join(format!("sirix-cli-overrides-{}", Uuid::new_v4()));
        let launch = AiLaunchConfig {
            effective_config: SirixConfig::default(),
            agent: SirixConfig::default()
                .agents
                .into_iter()
                .next()
                .expect("default agent should exist"),
            provider: SirixConfig::default()
                .providers
                .into_iter()
                .next()
                .expect("default provider should exist"),
            model: SirixConfig::default().providers[0].models[0].clone(),
            session_providers: SirixConfig::default().providers,
            codex_home: root.join("codex-home"),
            session_storage_dir: root.join("runtime").join("sessions").join("test"),
            workspace_root: root.join("workspace"),
            workspace_source: None,
        };

        let overrides = render_cli_overrides(
            &build_codex_bridge_toml(
                SirixConfig::default(),
                &launch,
                launch.workspace_root.as_path(),
                9700,
                Uuid::new_v4(),
            )
            .expect("bridge config should build"),
        )
        .expect("cli overrides should render");

        assert!(
            overrides
                .iter()
                .any(|item| item.starts_with("model_providers=") && item.contains("wire_api")),
            "session proxy provider should be rendered as a CLI override"
        );
        assert!(
            overrides
                .iter()
                .any(|item| item.starts_with("sandbox_workspace_write=")
                    && item.contains("network_access = true")),
            "workspace-write sandbox override should survive inline rendering"
        );

        if root.exists() {
            fs::remove_dir_all(&root).expect("temp tree should be cleaned up");
        }
    }

    #[test]
    fn ensure_layout_migrates_legacy_session_storage_into_shared_home() {
        let root = env::temp_dir().join(format!("sirix-storage-migration-{}", Uuid::new_v4()));
        let sirix_home = root.join("home");
        let legacy_codex_home = sirix_home
            .join("runtime")
            .join("sessions")
            .join(Uuid::new_v4().to_string())
            .join("codex-home");
        let legacy_rollout_dir = legacy_codex_home.join(SIRIX_SESSIONS_SUBDIR);
        fs::create_dir_all(&legacy_rollout_dir).expect("legacy rollout dir should exist");
        fs::write(
            legacy_rollout_dir.join("rollout-2026-04-13T00-00-00-thread.jsonl"),
            "{\"item\":\"legacy\"}\n",
        )
        .expect("legacy rollout should be written");
        fs::write(
            legacy_codex_home.join(SIRIX_SESSION_INDEX_FILE_NAME),
            "{\"id\":\"thread\",\"thread_name\":\"legacy\",\"updated_at\":\"2026-04-13T00:00:00Z\"}\n",
        )
        .expect("legacy session index should be written");
        fs::write(
            legacy_codex_home.join("config.toml"),
            format!(
                "[projects.\"{}\"]\ntrust_level = \"trusted\"\n",
                root.join("workspace").display()
            ),
        )
        .expect("legacy config should be written");

        let store = SirixConfigStore {
            sirix_home: sirix_home.clone(),
            config_path: sirix_home.join("config.toml"),
        };
        store.ensure_layout().expect("layout should be ensured");

        let shared_codex_home = store.shared_codex_home();
        assert!(
            shared_codex_home
                .join(SIRIX_SESSIONS_SUBDIR)
                .join("rollout-2026-04-13T00-00-00-thread.jsonl")
                .is_file(),
            "legacy rollouts should be moved into the stable shared Codex home"
        );
        assert!(
            fs::read_to_string(shared_codex_home.join(SIRIX_SESSION_INDEX_FILE_NAME))
                .expect("shared session index should exist")
                .contains("\"thread_name\":\"legacy\""),
            "legacy session names should survive the migration"
        );
        assert!(
            fs::read_to_string(shared_codex_home.join("config.toml"))
                .expect("shared config should exist")
                .contains("trust_level = \"trusted\""),
            "legacy trust decisions should be preserved in the shared config"
        );

        fs::remove_dir_all(&root).expect("temp tree should be cleaned up");
    }
}
