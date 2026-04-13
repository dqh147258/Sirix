use std::{
    collections::{BTreeMap, HashMap, HashSet},
    env,
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::Context;
use rmcp::model::{
    ClientCapabilities, ClientInfo, CreateElicitationRequestParams, CreateElicitationResult,
    ElicitationCapability, FormElicitationCapability, Implementation, Resource, ResourceTemplate,
    Tool,
};
use rmcp::service::{self, RequestContext};
use rmcp::transport::child_process::TokioChildProcess;
use rmcp::ClientHandler;
use rmcp::RoleClient;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncBufReadExt;
use tokio::io::BufReader;
use tokio::process::Command;
use toml::Value as TomlValue;
use uuid::Uuid;

const DEFAULT_AGENT_ID: &str = "default-agent";
const DEFAULT_PROVIDER_ID: &str = "openai";
const DEFAULT_MODEL_ID: &str = "gpt-5";
const SIRIX_SESSION_PROXY_PROVIDER_ID: &str = "sirix-session-proxy";
pub const SIRIX_AGENT_RUNTIME_FILE_NAME: &str = "sirix-agent-runtime.json";
pub const SIRIX_EXEC_POLICY_RULES_DIR: &str = "rules";
pub const SIRIX_EXEC_POLICY_RULES_FILE: &str = "default.rules";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    OpenAiCompatible,
    OpenAiResponses,
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
                name: "Default Agent".to_string(),
                description: "Default Sirix coding agent.".to_string(),
                provider_id: DEFAULT_PROVIDER_ID.to_string(),
                model_id: DEFAULT_MODEL_ID.to_string(),
                fallback_provider_id: String::new(),
                fallback_model_id: String::new(),
                system_prompt: String::new(),
                approval_mode: ApprovalMode::Ask,
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
        fs::create_dir_all(&self.sirix_home)
            .with_context(|| format!("failed to create {}", self.sirix_home.display()))?;
        let serialized =
            toml::to_string_pretty(config).context("failed to serialize sirix config")?;
        fs::write(&self.config_path, serialized)
            .with_context(|| format!("failed to write {}", self.config_path.display()))?;
        Ok(())
    }

    pub fn global_shell_rules_path(&self) -> PathBuf {
        self.sirix_home.join("shell-rules.json")
    }

    pub fn workspace_shell_rules_path(&self, cwd: &Path) -> PathBuf {
        cwd.join(".sirix").join("shell-rules.json")
    }

    pub fn load_global_shell_rules(&self) -> anyhow::Result<ShellRulesConfig> {
        self.load_shell_rules_from_path(&self.global_shell_rules_path())
    }

    pub fn save_global_shell_rules(&self, rules: &ShellRulesConfig) -> anyhow::Result<()> {
        self.save_shell_rules_to_path(&self.global_shell_rules_path(), rules)
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

    pub fn save_workspace_shell_rules(
        &self,
        cwd: &Path,
        rules: &ShellRulesConfig,
    ) -> anyhow::Result<()> {
        self.save_shell_rules_to_path(&self.workspace_shell_rules_path(cwd), rules)
    }

    pub fn effective_shell_rules(&self, cwd: &Path) -> anyhow::Result<ShellRulesConfig> {
        let global = self.load_global_shell_rules()?;
        let Some(workspace) = self.load_workspace_shell_rules(cwd)? else {
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
        let effective_shell_rules = merge_shell_rules(
            self.effective_shell_rules(cwd)?,
            session_shell_rules.clone(),
        );
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
        codex_home: &Path,
        runtime: &SessionAgentRuntimeConfig,
    ) -> anyhow::Result<()> {
        let path = codex_home.join(SIRIX_AGENT_RUNTIME_FILE_NAME);
        let serialized = serde_json::to_string_pretty(runtime)
            .context("failed to serialize session agent runtime")?;
        fs::write(&path, serialized).with_context(|| format!("failed to write {}", path.display()))
    }

    pub fn write_session_exec_policy_file(
        &self,
        codex_home: &Path,
        cwd: &Path,
        session_shell_rules: &ShellRulesConfig,
    ) -> anyhow::Result<()> {
        let effective_shell_rules = merge_shell_rules(
            self.effective_shell_rules(cwd)?,
            session_shell_rules.clone(),
        );
        let rules_dir = codex_home.join(SIRIX_EXEC_POLICY_RULES_DIR);
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
        fs::write(&path, body).with_context(|| format!("failed to write {}", path.display()))
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
        let codex_home = self
            .sirix_home
            .join("runtime")
            .join("sessions")
            .join(session_id.to_string())
            .join("codex-home");

        Ok(AiLaunchConfig {
            effective_config: config,
            agent,
            provider,
            model,
            session_providers,
            codex_home,
            workspace_root: cwd.to_path_buf(),
            workspace_source: effective.workspace_source.map(PathBuf::from),
        })
    }

    pub fn write_codex_bridge_config(
        &self,
        launch: &AiLaunchConfig,
        cwd: &Path,
        local_ws_port: u16,
        ai_session_id: Uuid,
    ) -> anyhow::Result<()> {
        fs::create_dir_all(&launch.codex_home)
            .with_context(|| format!("failed to create {}", launch.codex_home.display()))?;
        let config_value = build_codex_bridge_toml(
            launch.effective_config.clone(),
            launch,
            cwd,
            local_ws_port,
            ai_session_id,
        )?;
        let serialized = toml::to_string_pretty(&config_value)
            .context("failed to serialize codex bridge config")?;
        let config_path = launch.codex_home.join("config.toml");
        fs::write(&config_path, serialized)
            .with_context(|| format!("failed to write {}", config_path.display()))?;
        Ok(())
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
        Ok(())
    }

    fn load_shell_rules_from_path(&self, path: &Path) -> anyhow::Result<ShellRulesConfig> {
        if !path.exists() {
            if path == self.global_shell_rules_path() {
                let default_rules = ShellRulesConfig::default();
                self.save_shell_rules_to_path(path, &default_rules)?;
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

    fn save_shell_rules_to_path(
        &self,
        path: &Path,
        rules: &ShellRulesConfig,
    ) -> anyhow::Result<()> {
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

    // Sirix CLI 默认启动不显式传 agent_id，所以这里优先解析 `default-agent`。
    // 这样 Provider/Model 页面上设置的“默认模型”可以直接反映到 CLI 启动结果。
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

    let enabled_skills = effective
        .skills
        .iter()
        .filter(|item| item.enabled)
        .filter(|item| launch.agent.skill_ids.contains(&item.id))
        .map(|item| {
            let mut entry = toml::map::Map::<String, TomlValue>::new();
            entry.insert("path".to_string(), TomlValue::String(item.path.clone()));
            entry.insert("enabled".to_string(), TomlValue::Boolean(true));
            TomlValue::Table(entry)
        })
        .collect::<Vec<_>>();
    if !enabled_skills.is_empty() {
        let mut skills = toml::map::Map::<String, TomlValue>::new();
        skills.insert("config".to_string(), TomlValue::Array(enabled_skills));
        root.insert("skills".to_string(), TomlValue::Table(skills));
    }

    let enabled_mcp = effective
        .mcp_servers
        .iter()
        .filter(|item| item.enabled)
        .filter(|item| launch.agent.mcp_server_ids.contains(&item.id))
        .map(|item| {
            let mut value = parse_mcp_config_value(&item.json_config)
                .with_context(|| format!("invalid mcp config for {}", item.id))?;

            if !effective.mcp.enabled {
                return Ok(None);
            }
            match infer_mcp_transport(&value)
                .with_context(|| format!("mcp server {} has unknown transport", item.id))?
            {
                McpTransportKind::Stdio if !effective.mcp.allow_stdio => return Ok(None),
                McpTransportKind::Http if !effective.mcp.allow_http => return Ok(None),
                _ => {}
            }

            if let Some(table) = value.as_table_mut() {
                if !item.enabled_tools.is_empty() {
                    table.insert(
                        "enabled_tools".to_string(),
                        TomlValue::Array(
                            item.enabled_tools
                                .iter()
                                .cloned()
                                .map(TomlValue::String)
                                .collect(),
                        ),
                    );
                }
                if !item.disabled_tools.is_empty() {
                    table.insert(
                        "disabled_tools".to_string(),
                        TomlValue::Array(
                            item.disabled_tools
                                .iter()
                                .cloned()
                                .map(TomlValue::String)
                                .collect(),
                        ),
                    );
                }
            }
            Ok(Some((item.id.clone(), value)))
        })
        .collect::<anyhow::Result<Vec<_>>>()?
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    if !enabled_mcp.is_empty() {
        let mut servers = toml::map::Map::<String, TomlValue>::new();
        for (id, value) in enabled_mcp {
            servers.insert(id, value);
        }
        root.insert("mcp_servers".to_string(), TomlValue::Table(servers));
    }

    if let Some(workspace_source) = launch.workspace_source.as_ref() {
        if workspace_source.ends_with(Path::new(".codex").join("config.toml")) {
            let workspace_raw = fs::read_to_string(workspace_source)
                .with_context(|| format!("failed to read {}", workspace_source.display()))?;
            let workspace_value = toml::from_str::<TomlValue>(&workspace_raw)
                .with_context(|| format!("failed to parse {}", workspace_source.display()))?;
            if let Some(table) = workspace_value.as_table() {
                if effective.mcp.enabled {
                    if let Some(mcp) = table.get("mcp_servers") {
                        root.insert("mcp_servers".to_string(), mcp.clone());
                    }
                }
                if let Some(skills) = table.get("skills") {
                    root.insert("skills".to_string(), skills.clone());
                }
            }
        }
    }

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

    let mut seen_model_ids = HashSet::<String>::new();
    let mut models = Vec::new();
    for provider in ordered_providers {
        for model in provider.models.iter() {
            if !model.enabled || !matches!(model.model_kind, ModelKind::Text) {
                continue;
            }
            if !seen_model_ids.insert(model.id.clone()) {
                continue;
            }
            let mut entry = toml::map::Map::<String, TomlValue>::new();
            entry.insert("id".to_string(), TomlValue::String(model.id.clone()));
            entry.insert("model".to_string(), TomlValue::String(model.id.clone()));
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
                TomlValue::Boolean(model.id == default_model_id),
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

fn bridge_session_proxy_base_url(local_ws_port: u16, ai_session_id: Uuid) -> String {
    format!("http://127.0.0.1:{local_ws_port}/ai/sessions/{ai_session_id}/provider/v1")
}

fn normalize_sirix_config(config: &mut SirixConfig) {
    // Keep legacy config migration centralized here so the rest of the runtime
    // can rely on the newer Agent schema without duplicating fallback logic.
    let default_builtin_tools = default_builtin_tool_ids();
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
    }
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
        ProviderKind::OpenAiResponses if model_id.starts_with("gpt-5") => 400_000,
        ProviderKind::OpenAiResponses => 200_000,
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
    let value = toml::from_str::<TomlValue>(raw).context("legacy config is not valid TOML")?;
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
    let value = toml::from_str::<TomlValue>(raw).with_context(|| {
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

fn parse_mcp_config_value(raw: &str) -> anyhow::Result<TomlValue> {
    toml::from_str::<TomlValue>(raw)
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
        merged.deny.retain(|existing| existing != &rule);
    }
    for rule in overlay.deny {
        upsert_shell_rule(&mut merged.deny, &rule);
        merged.allow.retain(|existing| existing != &rule);
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

    // Render the capability inventory directly into developer instructions so the
    // preview button and the runtime stay aligned on what the current agent is
    // actually allowed to use. Tool gating still happens in the runtime layer;
    // this section exists to make those constraints legible to the model.
    if !agent.builtin_tool_ids.is_empty() {
        let mut section = String::from("<builtin_tools>\n");
        for tool_id in &agent.builtin_tool_ids {
            section.push_str(&format!("- {tool_id}\n"));
        }
        section.push_str("</builtin_tools>");
        sections.push(section);
    }

    let selected_skills = agent
        .skill_ids
        .iter()
        .filter_map(|id| config.skills.iter().find(|candidate| candidate.id == *id))
        .filter(|candidate| candidate.enabled)
        .collect::<Vec<_>>();
    if !selected_skills.is_empty() {
        let mut section = String::from("<skills>\n");
        for skill in selected_skills {
            let sandbox_scope = if skill.allow_outside_sandbox {
                "outside_sandbox_allowed"
            } else {
                "workspace_only"
            };
            section.push_str(&format!(
                "- {} ({}) path={} scope={}\n",
                skill.name,
                skill.id,
                skill.path.trim(),
                sandbox_scope
            ));
        }
        section.push_str("</skills>");
        sections.push(section);
    }

    let selected_mcp_servers = agent
        .mcp_server_ids
        .iter()
        .filter_map(|id| {
            config
                .mcp_servers
                .iter()
                .find(|candidate| candidate.id == *id)
        })
        .filter(|candidate| candidate.enabled)
        .collect::<Vec<_>>();
    if !selected_mcp_servers.is_empty() {
        let mut section = String::from("<mcp_servers>\n");
        for server in selected_mcp_servers {
            section.push_str(&format!(
                "- {} ({}) approval_mode={}\n",
                server.name,
                server.id,
                prompt_approval_mode_label(&server.approval_mode)
            ));
        }
        section.push_str("</mcp_servers>");
        sections.push(section);
    }

    let sub_agents = agent
        .sub_agent_ids
        .iter()
        .filter_map(|id| config.agents.iter().find(|candidate| candidate.id == *id))
        .filter(|candidate| candidate.enabled)
        .collect::<Vec<_>>();
    if !sub_agents.is_empty() {
        let mut section = String::from("<subagents>\n");
        for sub_agent in sub_agents {
            section.push_str(&format!("- {} ({})", sub_agent.name, sub_agent.id,));
            if !sub_agent.description.trim().is_empty() {
                section.push_str(&format!(": {}", sub_agent.description.trim()));
            }
            section.push('\n');
        }
        section.push_str("</subagents>");
        sections.push(section);
    }

    sections.join("\n\n")
}

pub async fn build_agent_system_prompt_preview(
    config: &SirixConfig,
    agent: &AgentConfig,
    sirix_home: &Path,
    workspace_root: Option<&Path>,
) -> anyhow::Result<String> {
    let mut sections = Vec::<String>::new();
    if !config.cli.supplemental_system_prompt.trim().is_empty() {
        sections.push(config.cli.supplemental_system_prompt.trim().to_string());
    }
    if !agent.system_prompt.trim().is_empty() {
        sections.push(agent.system_prompt.trim().to_string());
    }

    if let Some(section) = build_builtin_tool_prompt_section(&agent.builtin_tool_ids) {
        sections.push(section);
    }
    if let Some(section) = build_skill_prompt_section(config, agent) {
        sections.push(section);
    }
    if let Some(section) =
        build_mcp_server_prompt_section(config, agent, sirix_home, workspace_root).await?
    {
        sections.push(section);
    }
    if let Some(section) = build_sub_agent_prompt_section(config, agent) {
        sections.push(section);
    }

    Ok(sections.join("\n\n").trim().to_string())
}

fn build_skill_prompt_section(config: &SirixConfig, agent: &AgentConfig) -> Option<String> {
    let selected_skills = agent
        .skill_ids
        .iter()
        .filter_map(|id| config.skills.iter().find(|candidate| candidate.id == *id))
        .filter(|candidate| candidate.enabled)
        .collect::<Vec<_>>();
    if selected_skills.is_empty() {
        return None;
    }

    let mut section = String::from("# Skills\n\n");
    section.push_str(
        "These local skills are available to the selected agent and may extend workflow guidance or specialist behavior.\n",
    );
    for skill in selected_skills {
        let sandbox_scope = if skill.allow_outside_sandbox {
            "outside_sandbox_allowed"
        } else {
            "workspace_only"
        };
        section.push_str(&format!(
            "\n## {} (`{}`)\n- Path: `{}`\n- Scope: `{}`\n",
            skill.name,
            skill.id,
            skill.path.trim(),
            sandbox_scope
        ));
    }

    Some(section.trim().to_string())
}

fn build_sub_agent_prompt_section(config: &SirixConfig, agent: &AgentConfig) -> Option<String> {
    let sub_agents = agent
        .sub_agent_ids
        .iter()
        .filter_map(|id| config.agents.iter().find(|candidate| candidate.id == *id))
        .filter(|candidate| candidate.enabled)
        .collect::<Vec<_>>();
    if sub_agents.is_empty() {
        return None;
    }

    let mut section = String::from("# Sub Agents\n\n");
    section.push_str(
        "These Sirix agent profiles can be selected or referenced as sub-agents in this workspace.\n",
    );
    for sub_agent in sub_agents {
        section.push_str(&format!("\n## {} (`{}`)\n", sub_agent.name, sub_agent.id));
        if !sub_agent.description.trim().is_empty() {
            section.push_str(&format!(
                "- Description: {}\n",
                sub_agent.description.trim()
            ));
        } else {
            section.push_str("- Description: No description provided.\n");
        }
        section.push_str(&format!(
            "- Model: `{}` / `{}`\n",
            sub_agent.provider_id, sub_agent.model_id
        ));
    }

    Some(section.trim().to_string())
}

fn build_builtin_tool_prompt_section(tool_ids: &[String]) -> Option<String> {
    if tool_ids.is_empty() {
        return None;
    }

    let mut section = String::from("# Builtin Tools\n\n");
    section.push_str(
        "Only the builtin tools listed below should be treated as available. Each entry describes the intended use of that tool inside Sirix.\n",
    );
    for tool_id in tool_ids {
        let description = builtin_tool_prompt_description(tool_id.as_str());
        section.push_str(&format!("\n## `{tool_id}`\n{description}\n"));
    }
    Some(section.trim().to_string())
}

// The preview should expose the same intent and calling surface the model will
// see conceptually, instead of only listing opaque tool ids. Keeping these
// descriptions centralized here also avoids the settings page drifting away
// from the runtime capabilities when more tools are added later.
fn builtin_tool_prompt_description(tool_id: &str) -> &'static str {
    match tool_id {
        "shell" => {
            "Run a shell command in the workspace. Use this for short, direct command execution when no interactive follow-up is required."
        }
        "shell_command" => {
            "Run a structured shell command request. Use this when the runtime expects a shell invocation with explicit command arguments and approval handling."
        }
        "exec_command" => {
            "Start a command in a PTY and capture its output. Typical inputs include `cmd`, optional `workdir`, `yield_time_ms`, and `max_output_tokens`."
        }
        "write_stdin" => {
            "Send additional input to a command that is already running in an interactive PTY session. Use it to answer prompts, continue a REPL, or poll for more output."
        }
        "apply_patch" => {
            "Edit files through a structured patch payload. Prefer this when making targeted code changes so the diff is explicit and reviewable."
        }
        "update_plan" => {
            "Update the visible execution plan for the current task. Use it to record steps, statuses, and short explanations while working."
        }
        "request_user_input" => {
            "Pause execution and ask the user a short structured question with recommended options. Use this only when a blocking decision cannot be inferred safely."
        }
        "request_permissions" => {
            "Request extra `network` or `file_system` permissions before attempting an operation that would otherwise be blocked."
        }
        "view_image" => {
            "Attach a local image from disk so the model can inspect it in context. Use this before reasoning about screenshots or other local visual assets."
        }
        "web_search" => {
            "Search the web and optionally open result pages for up-to-date information. Use it when current external facts or references are required."
        }
        "image_generation" => {
            "Generate or edit images through the model-backed image tool when the task requires bitmap asset creation or transformation."
        }
        "code_mode" => {
            "Use the code-mode helper to inspect or generate tool-driven coding workflows when the runtime exposes a code-mode capability."
        }
        "js_repl" => {
            "Execute JavaScript snippets in the configured JS runtime. Use it for fast calculations, DOM-less script evaluation, or small data transformations."
        }
        "js_repl_reset" => {
            "Reset the JavaScript REPL session so the next `js_repl` call starts from a clean state."
        }
        "list_dir" => {
            "List directories and files from the local workspace when the runtime exposes directory browsing as a dedicated builtin."
        }
        "list_mcp_resources" => {
            "List direct MCP resources that a connected MCP server exposes."
        }
        "list_mcp_resource_templates" => {
            "List MCP resource templates that can later be materialized or read."
        }
        "read_mcp_resource" => {
            "Read a concrete MCP resource by URI after discovering it from the MCP resource listings."
        }
        "spawn_agent" => {
            "Create a sub-agent for a bounded parallel task. Use it only when delegation is explicitly allowed and the subtask is independent enough to run separately."
        }
        "send_message" => {
            "Send an additional message to an existing sub-agent so it can continue, refine, or redirect its assigned work."
        }
        "followup_task" => {
            "Schedule or enqueue a follow-up task for later execution when the runtime exposes deferred task orchestration."
        }
        "wait_agent" => {
            "Wait for one or more sub-agents to complete and return their final status."
        }
        "close_agent" => {
            "Close a sub-agent and release its resources once its work is no longer needed."
        }
        "list_agents" => {
            "List available sub-agents or delegated agent sessions that currently exist in the runtime."
        }
        _ => "Builtin tool available for this agent.",
    }
}

async fn build_mcp_server_prompt_section(
    config: &SirixConfig,
    agent: &AgentConfig,
    sirix_home: &Path,
    workspace_root: Option<&Path>,
) -> anyhow::Result<Option<String>> {
    let selected_servers = config
        .mcp_servers
        .iter()
        .filter(|candidate| candidate.enabled)
        .filter(|candidate| agent.mcp_server_ids.contains(&candidate.id))
        .collect::<Vec<_>>();
    if selected_servers.is_empty() || !config.mcp.enabled {
        return Ok(None);
    }

    let codex_home = sirix_home.join("runtime").join("prompt-preview");
    fs::create_dir_all(&codex_home)
        .with_context(|| format!("failed to create preview MCP home {}", codex_home.display()))?;

    let mut section = String::from("# MCP Servers\n\n");
    section.push_str(
        "The selected agent can access the following MCP servers. The preview expands each server into its currently discoverable tools, resources, and schemas.\n",
    );

    for server in selected_servers {
        let discovery =
            discover_mcp_server_capabilities(server, workspace_root, codex_home.as_path()).await;
        section.push_str(&format!("\n## {} (`{}`)\n", server.name, server.id));
        section.push_str(&format!(
            "- Approval Mode: `{}`\n",
            prompt_approval_mode_label(&server.approval_mode)
        ));
        section.push_str(&format!(
            "- Transport: `{}`\n",
            preview_mcp_transport_label(server)?
        ));
        match discovery {
            Ok(discovery) => {
                if let Some(instructions) = discovery
                    .instructions
                    .as_deref()
                    .filter(|value| !value.trim().is_empty())
                {
                    section.push_str("\n### Server Instructions\n");
                    section.push_str(instructions.trim());
                    section.push('\n');
                }

                render_mcp_tools_into_section(&mut section, &discovery.tools);
                render_mcp_resource_templates_into_section(
                    &mut section,
                    &discovery.resource_templates,
                );
                render_mcp_resources_into_section(&mut section, &discovery.resources);

                if !discovery.warnings.is_empty() {
                    section.push_str("\n### Discovery Notes\n");
                    for warning in discovery.warnings {
                        section.push_str(&format!("- {warning}\n"));
                    }
                }

                if discovery.tools.is_empty()
                    && discovery.resource_templates.is_empty()
                    && discovery.resources.is_empty()
                {
                    section.push_str(
                        "\n### Discovery Result\n- No tools or resources were discovered during preview. The server may require authentication, may have failed to initialize, or may simply expose no prompt-visible capabilities.\n",
                    );
                }
            }
            Err(error) => {
                section.push_str("\n### Discovery Error\n");
                section.push_str(&format!("- {}\n", error));
            }
        }
    }

    Ok(Some(section.trim().to_string()))
}

#[derive(Debug, Clone)]
struct PreviewMcpServerDiscovery {
    instructions: Option<String>,
    tools: Vec<Tool>,
    resource_templates: Vec<ResourceTemplate>,
    resources: Vec<Resource>,
    warnings: Vec<String>,
}

#[derive(Debug, Clone)]
enum PreviewMcpTransport {
    Stdio {
        program: OsString,
        args: Vec<OsString>,
        env: Option<HashMap<OsString, OsString>>,
        env_vars: Vec<String>,
        cwd: Option<PathBuf>,
    },
    Http {
        url: String,
    },
}

async fn discover_mcp_server_capabilities(
    server: &McpServerConfig,
    workspace_root: Option<&Path>,
    _codex_home: &Path,
) -> anyhow::Result<PreviewMcpServerDiscovery> {
    let transport = build_preview_mcp_transport(server, workspace_root)?;
    match transport {
        PreviewMcpTransport::Stdio {
            program,
            args,
            env,
            env_vars,
            cwd,
        } => discover_stdio_mcp_server_capabilities(server, program, args, env, env_vars, cwd).await,
        PreviewMcpTransport::Http { url, .. } => Ok(PreviewMcpServerDiscovery {
            instructions: None,
            tools: Vec::new(),
            resource_templates: Vec::new(),
            resources: Vec::new(),
            warnings: vec![format!(
                "HTTP MCP preview is not expanded yet. Server metadata is shown for `{url}`, but live tool/schema discovery currently runs only for stdio MCP servers."
            )],
        }),
    }
}

#[derive(Clone)]
struct PreviewClientHandler {
    client_info: ClientInfo,
}

impl ClientHandler for PreviewClientHandler {
    fn get_info(&self) -> ClientInfo {
        self.client_info.clone()
    }

    async fn create_elicitation(
        &self,
        _request: CreateElicitationRequestParams,
        _context: RequestContext<RoleClient>,
    ) -> Result<CreateElicitationResult, rmcp::ErrorData> {
        Err(rmcp::ErrorData::internal_error(
            "MCP elicitation is not supported while rendering prompt preview".to_string(),
            None,
        ))
    }
}

fn preview_client_info() -> ClientInfo {
    ClientInfo {
        meta: None,
        capabilities: ClientCapabilities {
            experimental: None,
            extensions: None,
            roots: None,
            sampling: None,
            elicitation: Some(ElicitationCapability {
                form: Some(FormElicitationCapability {
                    schema_validation: None,
                }),
                url: None,
            }),
            tasks: None,
        },
        client_info: Implementation {
            name: "sirix-preview".to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            title: Some("Sirix Prompt Preview".into()),
            description: None,
            icons: None,
            website_url: None,
        },
        protocol_version: rmcp::model::ProtocolVersion::V_2025_06_18,
    }
}

async fn discover_stdio_mcp_server_capabilities(
    server: &McpServerConfig,
    program: OsString,
    args: Vec<OsString>,
    env_overrides: Option<HashMap<OsString, OsString>>,
    env_vars: Vec<String>,
    cwd: Option<PathBuf>,
) -> anyhow::Result<PreviewMcpServerDiscovery> {
    let mut command = Command::new(&program);
    command
        .kill_on_drop(true)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .args(&args);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    if let Some(env_overrides) = env_overrides {
        command.envs(env_overrides);
    }
    for key in env_vars {
        if let Ok(value) = env::var(&key) {
            command.env(&key, value);
        }
    }
    #[cfg(unix)]
    command.process_group(0);

    let program_label = program.to_string_lossy().to_string();
    let (transport, stderr) = TokioChildProcess::builder(command)
        .spawn()
        .with_context(|| format!("failed to spawn MCP preview process {}", server.id))?;
    if let Some(stderr) = stderr {
        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr).lines();
            loop {
                match reader.next_line().await {
                    Ok(Some(line)) => {
                        tracing::info!("MCP preview stderr ({program_label}): {line}");
                    }
                    Ok(None) => break,
                    Err(error) => {
                        tracing::warn!(
                            "Failed to read MCP preview stderr ({program_label}): {error}"
                        );
                        break;
                    }
                }
            }
        });
    }

    let service = tokio::time::timeout(
        Duration::from_secs(6),
        service::serve_client(
            PreviewClientHandler {
                client_info: preview_client_info(),
            },
            transport,
        ),
    )
    .await
    .map_err(|_| anyhow::anyhow!("timed out handshaking with MCP server after 6s"))?
    .map_err(|error| anyhow::anyhow!("handshaking with MCP server failed: {error}"))?;

    let initialize_result = service
        .peer()
        .peer_info()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("handshake succeeded but server info was missing"))?;

    let mut warnings = Vec::new();
    let tools = match tokio::time::timeout(Duration::from_secs(4), service.list_tools(None)).await {
        Ok(Ok(result)) => result.tools,
        Ok(Err(error)) => {
            warnings.push(format!("tools/list failed: {error}"));
            Vec::new()
        }
        Err(_) => {
            warnings.push("tools/list timed out after 4s".to_string());
            Vec::new()
        }
    };
    let resources =
        match tokio::time::timeout(Duration::from_secs(4), service.list_resources(None)).await {
            Ok(Ok(result)) => result.resources,
            Ok(Err(error)) => {
                warnings.push(format!("resources/list failed: {error}"));
                Vec::new()
            }
            Err(_) => {
                warnings.push("resources/list timed out after 4s".to_string());
                Vec::new()
            }
        };
    let resource_templates = match tokio::time::timeout(
        Duration::from_secs(4),
        service.list_resource_templates(None),
    )
    .await
    {
        Ok(Ok(result)) => result.resource_templates,
        Ok(Err(error)) => {
            warnings.push(format!("resources/templates/list failed: {error}"));
            Vec::new()
        }
        Err(_) => {
            warnings.push("resources/templates/list timed out after 4s".to_string());
            Vec::new()
        }
    };

    Ok(PreviewMcpServerDiscovery {
        instructions: initialize_result.instructions,
        tools,
        resource_templates,
        resources,
        warnings,
    })
}

fn build_preview_mcp_transport(
    server: &McpServerConfig,
    workspace_root: Option<&Path>,
) -> anyhow::Result<PreviewMcpTransport> {
    let value = parse_mcp_config_value(&server.json_config)
        .with_context(|| format!("invalid mcp config for {}", server.id))?;
    let table = value
        .as_table()
        .context("MCP config must be a table/object")?;
    let transport = table.get("transport").and_then(TomlValue::as_table);

    match infer_mcp_transport(&value)? {
        McpTransportKind::Stdio => {
            let program = lookup_non_empty_string(table, &["command", "cmd"])
                .or_else(|| {
                    transport
                        .and_then(|nested| lookup_non_empty_string(nested, &["command", "cmd"]))
                })
                .context("stdio MCP transport requires command/cmd")?;
            let args = lookup_string_array(table, &["args"])?
                .or_else(|| {
                    transport
                        .and_then(|nested| lookup_string_array(nested, &["args"]).ok().flatten())
                })
                .unwrap_or_default()
                .into_iter()
                .map(OsString::from)
                .collect::<Vec<_>>();
            let env = lookup_string_map(table, &["env"])?
                .or_else(|| {
                    transport.and_then(|nested| lookup_string_map(nested, &["env"]).ok().flatten())
                })
                .map(|items| {
                    items
                        .into_iter()
                        .map(|(key, value)| (OsString::from(key), OsString::from(value)))
                        .collect::<HashMap<_, _>>()
                });
            let env_vars = lookup_string_array(table, &["env_vars"])?
                .or_else(|| {
                    transport.and_then(|nested| {
                        lookup_string_array(nested, &["env_vars"]).ok().flatten()
                    })
                })
                .unwrap_or_default();
            let cwd = lookup_non_empty_string(table, &["cwd"])
                .or_else(|| transport.and_then(|nested| lookup_non_empty_string(nested, &["cwd"])))
                .map(PathBuf::from)
                .map(|path| {
                    if path.is_relative() {
                        workspace_root.map_or(path.clone(), |root| root.join(path))
                    } else {
                        path
                    }
                });
            Ok(PreviewMcpTransport::Stdio {
                program: OsString::from(program),
                args,
                env,
                env_vars,
                cwd,
            })
        }
        McpTransportKind::Http => {
            let url = lookup_non_empty_string(table, &["url", "endpoint"])
                .or_else(|| {
                    transport
                        .and_then(|nested| lookup_non_empty_string(nested, &["url", "endpoint"]))
                })
                .context("http MCP transport requires url/endpoint")?;
            let bearer_token = lookup_non_empty_string(table, &["bearer_token"])
                .or_else(|| {
                    transport.and_then(|nested| lookup_non_empty_string(nested, &["bearer_token"]))
                })
                .or_else(|| {
                    lookup_non_empty_string(table, &["bearer_token_env_var"])
                        .and_then(|key| env::var(key).ok())
                })
                .or_else(|| {
                    transport
                        .and_then(|nested| {
                            lookup_non_empty_string(nested, &["bearer_token_env_var"])
                        })
                        .and_then(|key| env::var(key).ok())
                });
            let http_headers = lookup_string_map(table, &["http_headers"])?
                .or_else(|| {
                    transport.and_then(|nested| {
                        lookup_string_map(nested, &["http_headers"]).ok().flatten()
                    })
                })
                .map(|items| items.into_iter().collect::<HashMap<_, _>>());
            let env_http_headers = lookup_string_map(table, &["env_http_headers"])?
                .or_else(|| {
                    transport.and_then(|nested| {
                        lookup_string_map(nested, &["env_http_headers"])
                            .ok()
                            .flatten()
                    })
                })
                .map(|items| items.into_iter().collect::<HashMap<_, _>>());
            let _ = (bearer_token, http_headers, env_http_headers);
            Ok(PreviewMcpTransport::Http { url })
        }
    }
}

fn render_mcp_tools_into_section(section: &mut String, tools: &[Tool]) {
    if tools.is_empty() {
        return;
    }

    let mut ordered = tools.iter().collect::<Vec<_>>();
    ordered.sort_by(|left, right| left.name.cmp(&right.name));

    section.push_str("\n### Available Tools\n");
    for tool in ordered {
        section.push_str(&format!("\n- `{}`", tool.name));
        if let Some(description) = tool
            .description
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            section.push_str(&format!(": {}", description.trim()));
        }
        section.push('\n');
        section.push_str("  Input Schema:\n");
        section.push_str("  ```json\n");
        let input_schema = serde_json::to_value(tool.input_schema.as_ref())
            .unwrap_or_else(|_| serde_json::json!({}));
        section.push_str(&indent_json(&input_schema));
        section.push_str("\n  ```\n");
    }
}

fn render_mcp_resource_templates_into_section(
    section: &mut String,
    templates: &[ResourceTemplate],
) {
    if templates.is_empty() {
        return;
    }

    section.push_str("\n### Resource Templates\n");
    let mut ordered = templates.iter().collect::<Vec<_>>();
    ordered.sort_by(|left, right| left.uri_template.cmp(&right.uri_template));
    for template in ordered {
        let description = template.description.as_deref().unwrap_or("No description.");
        section.push_str(&format!(
            "- `{}` (`{}`): {}\n",
            template.uri_template, template.name, description
        ));
    }
}

fn render_mcp_resources_into_section(section: &mut String, resources: &[Resource]) {
    if resources.is_empty() {
        return;
    }

    section.push_str("\n### Direct Resources\n");
    let mut ordered = resources.iter().collect::<Vec<_>>();
    ordered.sort_by(|left, right| left.uri.cmp(&right.uri));
    for resource in ordered {
        let description = resource.description.as_deref().unwrap_or("No description.");
        section.push_str(&format!(
            "- `{}` (`{}`): {}\n",
            resource.uri, resource.name, description
        ));
    }
}

fn indent_json(value: &serde_json::Value) -> String {
    serde_json::to_string_pretty(value)
        .unwrap_or_else(|_| value.to_string())
        .lines()
        .map(|line| format!("  {line}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn preview_mcp_transport_label(server: &McpServerConfig) -> anyhow::Result<&'static str> {
    let value = parse_mcp_config_value(&server.json_config)
        .with_context(|| format!("invalid mcp config for {}", server.id))?;
    match infer_mcp_transport(&value)
        .with_context(|| format!("mcp server {} has unknown transport", server.id))?
    {
        McpTransportKind::Stdio => Ok("stdio"),
        McpTransportKind::Http => Ok("http"),
    }
}

fn prompt_approval_mode_label(mode: &ApprovalMode) -> &'static str {
    match mode {
        ApprovalMode::Allow => "allow",
        ApprovalMode::Ask => "ask",
        ApprovalMode::Deny => "deny",
    }
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

    let home = env::var("HOME")
        .or_else(|_| env::var("USERPROFILE"))
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
