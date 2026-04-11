use std::{
    collections::HashSet,
    env, fs,
    path::{Path, PathBuf},
};

use anyhow::Context;
use serde::{Deserialize, Serialize};
use toml::Value as TomlValue;
use uuid::Uuid;

const DEFAULT_AGENT_ID: &str = "default-agent";
const DEFAULT_PROVIDER_ID: &str = "openai";
const DEFAULT_MODEL_ID: &str = "gpt-5";

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
    AskOnce,
    AskEachTime,
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
}

impl Default for CliSettings {
    fn default() -> Self {
        Self {
            supplemental_system_prompt: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelConfig {
    pub id: String,
    pub display_name: String,
    pub model_kind: ModelKind,
    pub context_window: u32,
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
pub struct AgentConfig {
    pub id: String,
    pub name: String,
    pub provider_id: String,
    pub model_id: String,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default = "default_true")]
    pub builtin_tools_enabled: bool,
    #[serde(default)]
    pub enabled_skill_ids: Vec<String>,
    #[serde(default)]
    pub disabled_skill_ids: Vec<String>,
    #[serde(default)]
    pub enabled_mcp_server_ids: Vec<String>,
    #[serde(default)]
    pub disabled_mcp_server_ids: Vec<String>,
    #[serde(default)]
    pub capability_rules: Vec<AgentCapabilityRule>,
    #[serde(default = "default_true")]
    pub enabled: bool,
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
                base_url: "https://api.openai.com/v1".to_string(),
                api_key_env: "OPENAI_API_KEY".to_string(),
                api_key: String::new(),
                headers_json: "{}".to_string(),
                enabled: true,
                models: vec![ModelConfig {
                    id: DEFAULT_MODEL_ID.to_string(),
                    display_name: "GPT-5".to_string(),
                    model_kind: ModelKind::Text,
                    context_window: 200_000,
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
                provider_id: DEFAULT_PROVIDER_ID.to_string(),
                model_id: DEFAULT_MODEL_ID.to_string(),
                system_prompt: String::new(),
                builtin_tools_enabled: true,
                enabled_skill_ids: Vec::new(),
                disabled_skill_ids: Vec::new(),
                enabled_mcp_server_ids: Vec::new(),
                disabled_mcp_server_ids: Vec::new(),
                capability_rules: vec![
                    AgentCapabilityRule {
                        key: "builtin.shell".to_string(),
                        approval_mode: ApprovalMode::Allow,
                    },
                    AgentCapabilityRule {
                        key: "builtin.edit".to_string(),
                        approval_mode: ApprovalMode::Allow,
                    },
                    AgentCapabilityRule {
                        key: "builtin.plan".to_string(),
                        approval_mode: ApprovalMode::Allow,
                    },
                ],
                enabled: true,
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
    pub agent: AgentConfig,
    pub provider: ProviderConfig,
    pub model: ModelConfig,
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
            return Ok(EffectiveSirixConfig {
                config: merge_sirix_config(global, workspace),
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
            agent,
            provider,
            model,
            codex_home,
            workspace_root: cwd.to_path_buf(),
            workspace_source: effective.workspace_source.map(PathBuf::from),
        })
    }

    pub fn write_codex_bridge_config(
        &self,
        launch: &AiLaunchConfig,
        cwd: &Path,
    ) -> anyhow::Result<()> {
        fs::create_dir_all(&launch.codex_home)
            .with_context(|| format!("failed to create {}", launch.codex_home.display()))?;
        let config_value = build_codex_bridge_toml(self.load_global()?, launch, cwd)?;
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

        let target = bin_dir.join(sirix_binary_name);
        if target.exists() {
            let _ = fs::remove_file(&target);
        }

        #[cfg(unix)]
        std::os::unix::fs::symlink(&sirix_binary, &target).with_context(|| {
            format!(
                "failed to link {} -> {}",
                target.display(),
                sirix_binary.display()
            )
        })?;

        #[cfg(windows)]
        fs::copy(&sirix_binary, &target).with_context(|| {
            format!(
                "failed to copy {} -> {}",
                sirix_binary.display(),
                target.display()
            )
        })?;

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
}

fn resolve_agent(config: &SirixConfig, preferred: Option<&str>) -> anyhow::Result<AgentConfig> {
    if let Some(preferred) = preferred {
        if let Some(agent) = config
            .agents
            .iter()
            .find(|item| item.id == preferred && item.enabled)
            .cloned()
        {
            return Ok(agent);
        }
    }

    config
        .agents
        .iter()
        .find(|item| item.enabled)
        .cloned()
        .context("no enabled agent configured")
}

fn build_codex_bridge_toml(
    global: SirixConfig,
    launch: &AiLaunchConfig,
    cwd: &Path,
) -> anyhow::Result<toml::map::Map<String, TomlValue>> {
    let mut root = toml::map::Map::<String, TomlValue>::new();
    root.insert(
        "model".to_string(),
        TomlValue::String(launch.model.id.clone()),
    );
    root.insert(
        "model_provider".to_string(),
        TomlValue::String(launch.provider.id.clone()),
    );
    root.insert(
        "approval_policy".to_string(),
        TomlValue::String("never".to_string()),
    );
    root.insert(
        "sandbox_mode".to_string(),
        TomlValue::String("workspace-write".to_string()),
    );

    let mut instructions = String::new();
    if !global.cli.supplemental_system_prompt.trim().is_empty() {
        instructions.push_str(global.cli.supplemental_system_prompt.trim());
    }
    if !launch.agent.system_prompt.trim().is_empty() {
        if !instructions.is_empty() {
            instructions.push_str("\n\n");
        }
        instructions.push_str(launch.agent.system_prompt.trim());
    }
    if !instructions.is_empty() {
        root.insert("instructions".to_string(), TomlValue::String(instructions));
    }

    let provider_headers = parse_json_map(&launch.provider.headers_json)
        .with_context(|| format!("invalid headers_json for provider {}", launch.provider.id))?;
    let mut model_providers = toml::map::Map::<String, TomlValue>::new();
    let mut provider_value = toml::map::Map::<String, TomlValue>::new();
    provider_value.insert(
        "name".to_string(),
        TomlValue::String(launch.provider.name.clone()),
    );
    if !launch.provider.base_url.trim().is_empty() {
        provider_value.insert(
            "base_url".to_string(),
            TomlValue::String(launch.provider.base_url.clone()),
        );
    }
    if !launch.provider.api_key_env.trim().is_empty() {
        provider_value.insert(
            "env_key".to_string(),
            TomlValue::String(launch.provider.api_key_env.clone()),
        );
    }
    if !provider_headers.is_empty() {
        provider_value.insert(
            "http_headers".to_string(),
            TomlValue::Table(provider_headers),
        );
    }
    provider_value.insert(
        "wire_api".to_string(),
        TomlValue::String("responses".to_string()),
    );
    model_providers.insert(launch.provider.id.clone(), TomlValue::Table(provider_value));
    root.insert(
        "model_providers".to_string(),
        TomlValue::Table(model_providers),
    );

    let enabled_skills = global
        .skills
        .iter()
        .filter(|item| item.enabled)
        .filter(|item| {
            if !launch.agent.enabled_skill_ids.is_empty() {
                return launch.agent.enabled_skill_ids.contains(&item.id);
            }
            !launch.agent.disabled_skill_ids.contains(&item.id)
        })
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

    let enabled_mcp = global
        .mcp_servers
        .iter()
        .filter(|item| item.enabled)
        .filter(|item| {
            if !launch.agent.enabled_mcp_server_ids.is_empty() {
                return launch.agent.enabled_mcp_server_ids.contains(&item.id);
            }
            !launch.agent.disabled_mcp_server_ids.contains(&item.id)
        })
        .map(|item| {
            let mut value = parse_mcp_config_value(&item.json_config)
                .with_context(|| format!("invalid mcp config for {}", item.id))?;

            if !global.mcp.enabled {
                return Ok(None);
            }
            match infer_mcp_transport(&value)
                .with_context(|| format!("mcp server {} has unknown transport", item.id))?
            {
                McpTransportKind::Stdio if !global.mcp.allow_stdio => return Ok(None),
                McpTransportKind::Http if !global.mcp.allow_http => return Ok(None),
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
                if global.mcp.enabled {
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

    for provider in &config.providers {
        if provider.id.trim().is_empty() {
            anyhow::bail!("provider id cannot be empty");
        }
        if provider.name.trim().is_empty() {
            anyhow::bail!("provider {} name cannot be empty", provider.id);
        }
        ensure_unique_ids(provider.models.iter().map(|item| item.id.as_str()), "model")?;
        for model in &provider.models {
            if model.id.trim().is_empty() {
                anyhow::bail!("provider {} has model with empty id", provider.id);
            }
            if model.display_name.trim().is_empty() {
                anyhow::bail!("model {} display_name cannot be empty", model.id);
            }
            if model.context_window == 0 {
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
        ensure_known_ids(
            &agent.enabled_skill_ids,
            &skill_ids,
            &format!("agent {} enabled_skill_ids", agent.id),
        )?;
        ensure_known_ids(
            &agent.disabled_skill_ids,
            &skill_ids,
            &format!("agent {} disabled_skill_ids", agent.id),
        )?;
        ensure_known_ids(
            &agent.enabled_mcp_server_ids,
            &mcp_ids,
            &format!("agent {} enabled_mcp_server_ids", agent.id),
        )?;
        ensure_known_ids(
            &agent.disabled_mcp_server_ids,
            &mcp_ids,
            &format!("agent {} disabled_mcp_server_ids", agent.id),
        )?;
        ensure_unique_ids(
            agent.capability_rules.iter().map(|item| item.key.as_str()),
            "capability rule",
        )?;
        for rule in &agent.capability_rules {
            if rule.key.trim().is_empty() {
                anyhow::bail!("agent {} has empty capability rule key", agent.id);
            }
        }
    }

    Ok(())
}

fn parse_json_map(raw: &str) -> anyhow::Result<toml::map::Map<String, TomlValue>> {
    if raw.trim().is_empty() {
        return Ok(toml::map::Map::new());
    }
    let value = serde_json::from_str::<serde_json::Value>(raw)?;
    match value {
        serde_json::Value::Object(map) => Ok(map
            .into_iter()
            .map(|(key, value)| (key, toml_from_json(value)))
            .collect()),
        _ => anyhow::bail!("expected JSON object"),
    }
}

fn parse_config_with_compat(raw: &str, source: &Path) -> anyhow::Result<SirixConfig> {
    match toml::from_str::<SirixConfig>(raw) {
        Ok(parsed) => Ok(parsed),
        Err(primary_error) => parse_legacy_codex_config(raw).with_context(|| {
            format!(
                "failed to parse {} as Sirix config ({primary_error})",
                source.display()
            )
        }),
    }
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
            context_window,
            supports_images: true,
            enabled: true,
        }];
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
            context_window,
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
        cli: if overlay.cli.supplemental_system_prompt.trim().is_empty() {
            base.cli
        } else {
            overlay.cli
        },
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

fn default_true() -> bool {
    true
}

fn default_config_version() -> u32 {
    1
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

    #[test]
    fn parses_legacy_codex_global_config() {
        let raw = r#"
model = "gpt-5.4"
model_provider = "crs"
model_context_window = 400000
instructions = "legacy prompt"

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
        assert_eq!(parsed.providers.len(), 1);
        assert_eq!(parsed.providers[0].id, "crs");
        assert_eq!(parsed.providers[0].kind, ProviderKind::OpenAiResponses);
        assert_eq!(parsed.providers[0].models[0].id, "gpt-5.4");
        assert_eq!(parsed.providers[0].models[0].context_window, 400000);
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
}
