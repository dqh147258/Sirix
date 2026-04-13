use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::Context;
use chrono::{DateTime, Duration, Utc};
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::app::{
    ai::config::{
        resolve_session_picker_model, AiLaunchConfig, ApprovalMode, ProviderConfig,
        SessionAgentRuntimeConfig, ShellRulesConfig, SirixConfigStore,
    },
    state::AppState,
};

#[derive(Debug, Clone, serde::Serialize)]
pub struct AiSessionLaunchResponse {
    pub ai_session_id: Uuid,
    pub terminal_id: Uuid,
    pub mirrored_to_backend: bool,
    pub local_ws_port: u16,
    pub created_locally: bool,
    pub reuse_current_terminal: bool,
    pub current_terminal_launch: Option<CurrentTerminalLaunch>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct AiSessionRecord {
    pub ai_session_id: Uuid,
    pub terminal_id: Uuid,
    pub cwd: String,
    pub agent_id: String,
    pub model_id: String,
    pub mirrored_to_backend: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct CurrentTerminalLaunch {
    pub codex_executable: String,
    pub workspace_root: String,
    pub codex_home: String,
    pub provider_api_key_env: Option<String>,
    pub provider_api_key: Option<String>,
}

#[derive(Default)]
pub struct AiSessionRegistry {
    state: Arc<RwLock<AiSessionRegistryState>>,
}

#[derive(Default)]
struct AiSessionRegistryState {
    sessions: HashMap<Uuid, AiSessionRecord>,
    terminal_index: HashMap<Uuid, Uuid>,
    provider_index: HashMap<Uuid, SessionProviderRouting>,
}

#[derive(Debug, Clone)]
struct SessionProviderRouting {
    active_provider_id: String,
    providers: Vec<ProviderConfig>,
    codex_home: PathBuf,
    workspace_root: PathBuf,
    current_agent_id: String,
    current_model_id: String,
    current_shell_mode: ApprovalMode,
    builtin_tool_ids: Vec<String>,
    session_shell_rules: ShellRulesConfig,
    fallback: SessionFallbackState,
}

#[derive(Debug, Clone)]
pub struct SessionRuntimeSnapshot {
    pub ai_session_id: Uuid,
    pub terminal_id: Uuid,
    pub cwd: String,
    pub agent_id: String,
    pub model_id: String,
    pub codex_home: PathBuf,
    pub workspace_root: PathBuf,
    pub shell_mode: ApprovalMode,
    pub builtin_tool_ids: Vec<String>,
    pub session_shell_rules: ShellRulesConfig,
    pub fallback: SessionFallbackState,
}

#[derive(Debug, Clone, Default)]
pub struct SessionFallbackState {
    pub primary_provider_id: String,
    pub primary_model_id: String,
    pub fallback_provider_id: String,
    pub fallback_model_id: String,
    pub primary_failure_count: u32,
    pub primary_disabled_until: Option<DateTime<Utc>>,
}

impl AiSessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn insert(
        &self,
        record: AiSessionRecord,
        launch: &AiLaunchConfig,
        runtime: SessionAgentRuntimeConfig,
    ) {
        let ai_session_id = record.ai_session_id;
        let terminal_id = record.terminal_id;
        let mut state = self.state.write().await;
        if let Some(previous_ai_session_id) =
            state.terminal_index.insert(terminal_id, ai_session_id)
        {
            state.sessions.remove(&previous_ai_session_id);
            state.provider_index.remove(&previous_ai_session_id);
        }
        state.provider_index.insert(
            ai_session_id,
            SessionProviderRouting {
                active_provider_id: launch.provider.id.clone(),
                providers: launch.session_providers.clone(),
                codex_home: launch.codex_home.clone(),
                workspace_root: launch.workspace_root.clone(),
                current_agent_id: runtime.agent_id,
                current_model_id: launch.model.id.clone(),
                current_shell_mode: runtime.shell_mode,
                builtin_tool_ids: runtime.builtin_tool_ids,
                session_shell_rules: ShellRulesConfig {
                    version: 1,
                    mode: ApprovalMode::Ask,
                    allow: Vec::new(),
                    deny: Vec::new(),
                },
                fallback: SessionFallbackState {
                    primary_provider_id: launch.agent.provider_id.clone(),
                    primary_model_id: launch.agent.model_id.clone(),
                    fallback_provider_id: launch.agent.fallback_provider_id.clone(),
                    fallback_model_id: launch.agent.fallback_model_id.clone(),
                    primary_failure_count: 0,
                    primary_disabled_until: None,
                },
            },
        );
        state.sessions.insert(ai_session_id, record);
    }

    pub async fn list(&self) -> Vec<AiSessionRecord> {
        let state = self.state.read().await;
        let mut items = state.sessions.values().cloned().collect::<Vec<_>>();
        items.sort_by(|left, right| left.ai_session_id.cmp(&right.ai_session_id));
        items
    }

    pub async fn resolve(&self, any_id: Uuid) -> Option<AiSessionRecord> {
        let state = self.state.read().await;
        if let Some(record) = state.sessions.get(&any_id).cloned() {
            return Some(record);
        }
        let mapped = state.terminal_index.get(&any_id).copied()?;
        state.sessions.get(&mapped).cloned()
    }

    pub async fn resolve_provider_for_model(
        &self,
        ai_session_id: Uuid,
        model_id: &str,
    ) -> Option<ProviderConfig> {
        let state = self.state.read().await;
        let routing = state.provider_index.get(&ai_session_id)?;
        resolve_provider_for_model(routing, model_id)
    }

    pub async fn resolve_runtime(&self, ai_session_id: Uuid) -> Option<SessionRuntimeSnapshot> {
        let state = self.state.read().await;
        let record = state.sessions.get(&ai_session_id)?.clone();
        let routing = state.provider_index.get(&ai_session_id)?.clone();
        Some(SessionRuntimeSnapshot {
            ai_session_id: record.ai_session_id,
            terminal_id: record.terminal_id,
            cwd: record.cwd,
            agent_id: record.agent_id,
            model_id: record.model_id,
            codex_home: routing.codex_home,
            workspace_root: routing.workspace_root,
            shell_mode: routing.current_shell_mode,
            builtin_tool_ids: routing.builtin_tool_ids,
            session_shell_rules: routing.session_shell_rules,
            fallback: routing.fallback,
        })
    }

    pub async fn update_runtime(
        &self,
        ai_session_id: Uuid,
        launch: &AiLaunchConfig,
        runtime: SessionAgentRuntimeConfig,
    ) -> Option<()> {
        let mut state = self.state.write().await;
        let record = state.sessions.get_mut(&ai_session_id)?;
        record.agent_id = launch.agent.id.clone();
        record.model_id = launch.model.id.clone();
        let routing = state.provider_index.get_mut(&ai_session_id)?;
        routing.active_provider_id = launch.provider.id.clone();
        routing.providers = launch.session_providers.clone();
        routing.codex_home = launch.codex_home.clone();
        routing.workspace_root = launch.workspace_root.clone();
        routing.current_agent_id = runtime.agent_id;
        routing.current_model_id = launch.model.id.clone();
        routing.current_shell_mode = runtime.shell_mode;
        routing.builtin_tool_ids = runtime.builtin_tool_ids;
        routing.fallback = SessionFallbackState {
            primary_provider_id: launch.agent.provider_id.clone(),
            primary_model_id: launch.agent.model_id.clone(),
            fallback_provider_id: launch.agent.fallback_provider_id.clone(),
            fallback_model_id: launch.agent.fallback_model_id.clone(),
            primary_failure_count: 0,
            primary_disabled_until: None,
        };
        Some(())
    }

    pub async fn push_session_shell_rule(
        &self,
        ai_session_id: Uuid,
        decision: ApprovalMode,
        prefix: String,
    ) -> Option<()> {
        let mut state = self.state.write().await;
        let routing = state.provider_index.get_mut(&ai_session_id)?;
        match decision {
            ApprovalMode::Allow => {
                routing
                    .session_shell_rules
                    .deny
                    .retain(|item| item != &prefix);
                if !routing.session_shell_rules.allow.contains(&prefix) {
                    routing.session_shell_rules.allow.push(prefix);
                }
            }
            ApprovalMode::Deny => {
                routing
                    .session_shell_rules
                    .allow
                    .retain(|item| item != &prefix);
                if !routing.session_shell_rules.deny.contains(&prefix) {
                    routing.session_shell_rules.deny.push(prefix);
                }
            }
            ApprovalMode::Ask => {}
        }
        Some(())
    }

    pub async fn record_primary_model_failure(
        &self,
        ai_session_id: Uuid,
        requested_model_id: &str,
    ) -> Option<SessionFallbackState> {
        let mut state = self.state.write().await;
        let routing = state.provider_index.get_mut(&ai_session_id)?;
        if routing.fallback.primary_model_id != requested_model_id
            || routing.fallback.fallback_model_id.trim().is_empty()
        {
            return Some(routing.fallback.clone());
        }
        routing.fallback.primary_failure_count += 1;
        if routing.fallback.primary_failure_count >= 3 {
            routing.fallback.primary_disabled_until = Some(Utc::now() + Duration::hours(1));
        }
        Some(routing.fallback.clone())
    }

    pub async fn record_primary_model_success(
        &self,
        ai_session_id: Uuid,
        requested_model_id: &str,
    ) -> Option<()> {
        let mut state = self.state.write().await;
        let routing = state.provider_index.get_mut(&ai_session_id)?;
        if routing.fallback.primary_model_id == requested_model_id {
            routing.fallback.primary_failure_count = 0;
            routing.fallback.primary_disabled_until = None;
        }
        Some(())
    }

    pub async fn resolve_session_providers(
        &self,
        ai_session_id: Uuid,
    ) -> Option<(String, Vec<ProviderConfig>)> {
        let state = self.state.read().await;
        state.provider_index.get(&ai_session_id).map(|routing| {
            (
                routing.active_provider_id.clone(),
                routing.providers.clone(),
            )
        })
    }
}

pub async fn reconfigure_ai_session_agent(
    state: &AppState,
    config_store: &SirixConfigStore,
    ai_session_id: Uuid,
    agent_id: &str,
) -> anyhow::Result<(AiLaunchConfig, SessionAgentRuntimeConfig)> {
    let runtime = state
        .ai_session_registry
        .resolve_runtime(ai_session_id)
        .await
        .with_context(|| format!("ai session not found for id={ai_session_id}"))?;
    let launch = config_store.build_launch_config(
        runtime.workspace_root.as_path(),
        Some(agent_id),
        ai_session_id,
    )?;
    let session_runtime = config_store.build_session_agent_runtime(
        runtime.workspace_root.as_path(),
        &launch.agent,
        &runtime.session_shell_rules,
    )?;
    let runtime_state = state.runtime.read().await;
    let local_ws_port = runtime_state.local_ws_port;
    drop(runtime_state);
    config_store.write_codex_bridge_config(
        &launch,
        runtime.workspace_root.as_path(),
        local_ws_port,
        ai_session_id,
    )?;
    config_store.write_session_agent_runtime_file(&launch.codex_home, &session_runtime)?;
    config_store.write_session_exec_policy_file(
        &launch.codex_home,
        runtime.workspace_root.as_path(),
        &runtime.session_shell_rules,
    )?;
    state
        .ai_session_registry
        .update_runtime(ai_session_id, &launch, session_runtime.clone())
        .await
        .with_context(|| format!("failed to update ai session runtime for {ai_session_id}"))?;
    Ok((launch, session_runtime))
}

fn resolve_provider_for_model(
    routing: &SessionProviderRouting,
    model_id: &str,
) -> Option<ProviderConfig> {
    if let Some((provider, model)) = resolve_session_picker_model(&routing.providers, model_id) {
        if !should_use_fallback_model(&routing.fallback, model.id.as_str()) {
            return Some(provider.clone());
        }
    }

    let resolved_model_id = if should_use_fallback_model(&routing.fallback, model_id.trim()) {
        routing.fallback.fallback_model_id.as_str()
    } else {
        model_id.trim()
    };
    let trimmed_model_id = resolved_model_id.trim();
    if trimmed_model_id.is_empty() {
        return routing
            .providers
            .iter()
            .find(|provider| provider.id == routing.active_provider_id)
            .cloned()
            .or_else(|| routing.providers.first().cloned());
    }

    routing
        .providers
        .iter()
        .filter(|provider| provider.enabled)
        .filter(|provider| {
            provider
                .models
                .iter()
                .any(|model| model.enabled && model.id == trimmed_model_id)
        })
        .min_by_key(|provider| {
            (
                provider.id != routing.active_provider_id,
                provider.name.to_ascii_lowercase(),
                provider.id.to_ascii_lowercase(),
            )
        })
        .cloned()
}

fn should_use_fallback_model(state: &SessionFallbackState, model_id: &str) -> bool {
    !state.fallback_model_id.trim().is_empty()
        && state.primary_model_id == model_id
        && state
            .primary_disabled_until
            .is_some_and(|until| until > Utc::now())
}

pub async fn launch_ai_session(
    state: &AppState,
    config_store: &SirixConfigStore,
    cwd: &Path,
    agent_id: Option<&str>,
    cols: u16,
    rows: u16,
) -> anyhow::Result<AiSessionLaunchResponse> {
    let mut ai_session_id = Uuid::new_v4();
    let mut terminal_id = Uuid::new_v4();
    let launch = config_store.build_launch_config(cwd, agent_id, ai_session_id)?;
    let mut mirrored_to_backend = false;
    if remote_sync_available(state).await {
        match try_register_remote_ai_session(
            state,
            cwd,
            cols,
            rows,
            ai_session_id,
            terminal_id,
            &launch,
        )
        .await
        {
            Ok(Some(remote_registered)) => {
                ai_session_id = remote_registered.ai_session_id;
                terminal_id = remote_registered.terminal_id;
                mirrored_to_backend = true;
            }
            Ok(None) => {}
            Err(error) => {
                state
                    .logger
                    .warn(format!("failed to register remote ai session: {error}"));
            }
        }
    }

    let launch = config_store.build_launch_config(cwd, agent_id, ai_session_id)?;
    let resolved_agent_id = launch.agent.id.clone();
    let resolved_model_id = launch.model.id.clone();
    let launch_runtime = config_store.build_session_agent_runtime(
        cwd,
        &launch.agent,
        &ShellRulesConfig {
            version: 1,
            mode: ApprovalMode::Ask,
            allow: Vec::new(),
            deny: Vec::new(),
        },
    )?;
    let runtime = state.runtime.read().await;
    let local_ws_port = runtime.local_ws_port;
    drop(runtime);
    config_store.write_codex_bridge_config(&launch, cwd, local_ws_port, ai_session_id)?;
    config_store.write_session_agent_runtime_file(&launch.codex_home, &launch_runtime)?;
    config_store.write_session_exec_policy_file(
        &launch.codex_home,
        cwd,
        &ShellRulesConfig {
            version: 1,
            mode: ApprovalMode::Ask,
            allow: Vec::new(),
            deny: Vec::new(),
        },
    )?;
    let launch_for_registry = launch.clone();
    state
        .terminal_manager
        .create_codex_terminal(
            terminal_id,
            launch,
            ai_session_id,
            local_ws_port,
            cols,
            rows,
            mirrored_to_backend,
        )
        .await
        .context("failed to create codex-backed terminal")?;

    state
        .ai_session_registry
        .insert(
            AiSessionRecord {
                ai_session_id,
                terminal_id,
                cwd: cwd.display().to_string(),
                agent_id: resolved_agent_id,
                model_id: resolved_model_id,
                mirrored_to_backend,
            },
            &launch_for_registry,
            launch_runtime,
        )
        .await;

    let runtime = state.runtime.read().await;
    Ok(AiSessionLaunchResponse {
        ai_session_id,
        terminal_id,
        mirrored_to_backend,
        local_ws_port: runtime.local_ws_port,
        created_locally: true,
        reuse_current_terminal: false,
        current_terminal_launch: None,
    })
}

pub async fn launch_ai_session_in_current_terminal(
    state: &AppState,
    config_store: &SirixConfigStore,
    terminal_id: Uuid,
    cwd: &Path,
    agent_id: Option<&str>,
) -> anyhow::Result<AiSessionLaunchResponse> {
    state
        .terminal_manager
        .get_snapshot(terminal_id)
        .await
        .with_context(|| format!("terminal session not found for id={terminal_id}"))?;

    let ai_session_id = Uuid::new_v4();
    let launch = config_store.build_launch_config(cwd, agent_id, ai_session_id)?;
    let resolved_agent_id = launch.agent.id.clone();
    let resolved_model_id = launch.model.id.clone();
    let launch_runtime = config_store.build_session_agent_runtime(
        cwd,
        &launch.agent,
        &ShellRulesConfig {
            version: 1,
            mode: ApprovalMode::Ask,
            allow: Vec::new(),
            deny: Vec::new(),
        },
    )?;
    let runtime = state.runtime.read().await;
    let local_ws_port = runtime.local_ws_port;
    drop(runtime);
    config_store.write_codex_bridge_config(&launch, cwd, local_ws_port, ai_session_id)?;
    config_store.write_session_agent_runtime_file(&launch.codex_home, &launch_runtime)?;
    config_store.write_session_exec_policy_file(
        &launch.codex_home,
        cwd,
        &ShellRulesConfig {
            version: 1,
            mode: ApprovalMode::Ask,
            allow: Vec::new(),
            deny: Vec::new(),
        },
    )?;

    state
        .ai_session_registry
        .insert(
            AiSessionRecord {
                ai_session_id,
                terminal_id,
                cwd: cwd.display().to_string(),
                agent_id: resolved_agent_id,
                model_id: resolved_model_id,
                mirrored_to_backend: false,
            },
            &launch,
            launch_runtime,
        )
        .await;

    let runtime = state.runtime.read().await;
    Ok(AiSessionLaunchResponse {
        ai_session_id,
        terminal_id,
        mirrored_to_backend: false,
        local_ws_port: runtime.local_ws_port,
        created_locally: true,
        reuse_current_terminal: true,
        current_terminal_launch: Some(CurrentTerminalLaunch {
            codex_executable: super::super::terminal::manager::resolve_codex_executable()?,
            workspace_root: launch.workspace_root.display().to_string(),
            codex_home: launch.codex_home.display().to_string(),
            provider_api_key_env: (!launch.provider.api_key_env.trim().is_empty())
                .then(|| launch.provider.api_key_env.clone()),
            provider_api_key: (!launch.provider.api_key.trim().is_empty())
                .then(|| launch.provider.api_key.clone()),
        }),
    })
}

async fn remote_sync_available(state: &AppState) -> bool {
    let runtime = state.runtime.read().await;
    if !runtime.backend_event_stream_connected {
        return false;
    }
    drop(runtime);

    let Some(session) = state.auth_session_store.current_session().await else {
        return false;
    };

    !session.access_token.trim().is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::ai::config::{
        ApprovalMode, ModelConfig, ModelKind, ProviderKind, SessionAgentRuntimeConfig, SirixConfig,
    };

    fn test_provider(id: &str) -> ProviderConfig {
        ProviderConfig {
            id: id.to_string(),
            name: id.to_string(),
            kind: ProviderKind::OpenAiCompatible,
            default_context_window: Some(32_000),
            base_url: "https://example.com/v1".to_string(),
            api_key_env: "TEST_API_KEY".to_string(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![ModelConfig {
                id: "model".to_string(),
                display_name: "Model".to_string(),
                model_kind: ModelKind::Text,
                context_window: None,
                supports_images: false,
                enabled: true,
            }],
        }
    }

    fn test_launch(provider_id: &str) -> AiLaunchConfig {
        let provider = test_provider(provider_id);
        let mut agent = SirixConfig::default()
            .agents
            .into_iter()
            .next()
            .expect("default agent should exist");
        agent.id = format!("agent-{provider_id}");
        agent.provider_id = provider.id.clone();
        agent.model_id = "model".to_string();
        AiLaunchConfig {
            effective_config: SirixConfig::default(),
            agent,
            provider: provider.clone(),
            model: provider.models[0].clone(),
            session_providers: vec![provider],
            codex_home: PathBuf::from("/tmp/.sirix"),
            workspace_root: PathBuf::from("/tmp/workspace"),
            workspace_source: None,
        }
    }

    fn test_runtime(agent_id: &str) -> SessionAgentRuntimeConfig {
        SessionAgentRuntimeConfig {
            agent_id: agent_id.to_string(),
            shell_mode: ApprovalMode::Ask,
            builtin_tool_ids: vec!["shell".to_string()],
        }
    }

    #[tokio::test]
    async fn insert_replaces_previous_session_for_same_terminal() {
        let registry = AiSessionRegistry::new();
        let terminal_id = Uuid::new_v4();
        let first = AiSessionRecord {
            ai_session_id: Uuid::new_v4(),
            terminal_id,
            cwd: "/tmp/first".to_string(),
            agent_id: "agent-a".to_string(),
            model_id: "model-a".to_string(),
            mirrored_to_backend: false,
        };
        let second = AiSessionRecord {
            ai_session_id: Uuid::new_v4(),
            terminal_id,
            cwd: "/tmp/second".to_string(),
            agent_id: "agent-b".to_string(),
            model_id: "model-b".to_string(),
            mirrored_to_backend: true,
        };

        registry
            .insert(
                first.clone(),
                &test_launch("provider-a"),
                test_runtime("agent-a"),
            )
            .await;
        registry
            .insert(
                second.clone(),
                &test_launch("provider-b"),
                test_runtime("agent-b"),
            )
            .await;

        assert_eq!(registry.list().await, vec![second.clone()]);
        assert!(registry.resolve(first.ai_session_id).await.is_none());
        assert_eq!(
            registry.resolve(second.ai_session_id).await,
            Some(second.clone())
        );
        assert_eq!(registry.resolve(terminal_id).await, Some(second.clone()));
        assert!(registry
            .resolve_provider_for_model(first.ai_session_id, "model")
            .await
            .is_none());
        assert_eq!(
            registry
                .resolve_provider_for_model(second.ai_session_id, "model")
                .await
                .map(|provider| provider.id),
            Some("provider-b".to_string())
        );
    }

    #[tokio::test]
    async fn resolves_duplicate_model_ids_to_active_provider_first() {
        let registry = AiSessionRegistry::new();
        let record = AiSessionRecord {
            ai_session_id: Uuid::new_v4(),
            terminal_id: Uuid::new_v4(),
            cwd: "/tmp/workspace".to_string(),
            agent_id: "agent".to_string(),
            model_id: "shared-model".to_string(),
            mirrored_to_backend: false,
        };

        registry
            .insert(
                record.clone(),
                &AiLaunchConfig {
                    session_providers: vec![
                        test_provider("provider-a"),
                        test_provider("provider-b"),
                    ],
                    ..test_launch("provider-b")
                },
                test_runtime("agent"),
            )
            .await;

        assert_eq!(
            registry
                .resolve_provider_for_model(record.ai_session_id, "model")
                .await
                .map(|provider| provider.id),
            Some("provider-b".to_string())
        );
    }

    #[tokio::test]
    async fn resolves_provider_scoped_alias_to_matching_provider() {
        let registry = AiSessionRegistry::new();
        let record = AiSessionRecord {
            ai_session_id: Uuid::new_v4(),
            terminal_id: Uuid::new_v4(),
            cwd: "/tmp/workspace".to_string(),
            agent_id: "agent".to_string(),
            model_id: "shared-model".to_string(),
            mirrored_to_backend: false,
        };

        let mut primary = test_provider("provider-a");
        primary.models = vec![ModelConfig {
            id: "shared-model".to_string(),
            display_name: "Shared Model".to_string(),
            model_kind: ModelKind::Text,
            context_window: Some(128_000),
            supports_images: false,
            enabled: true,
        }];

        let mut secondary = test_provider("provider-b");
        secondary.kind = super::super::config::ProviderKind::OpenAiCodexOauth;
        secondary.base_url = "https://chatgpt.com/backend-api/codex".to_string();
        secondary.models = vec![ModelConfig {
            id: "shared-model".to_string(),
            display_name: "Shared Model".to_string(),
            model_kind: ModelKind::Text,
            context_window: Some(400_000),
            supports_images: false,
            enabled: true,
        }];

        registry
            .insert(
                record.clone(),
                &AiLaunchConfig {
                    session_providers: vec![primary, secondary],
                    ..test_launch("provider-b")
                },
                test_runtime("agent"),
            )
            .await;

        assert_eq!(
            registry
                .resolve_provider_for_model(record.ai_session_id, "shared-model @ provider-a")
                .await
                .map(|provider| provider.id),
            Some("provider-a".to_string())
        );
        assert_eq!(
            registry
                .resolve_provider_for_model(record.ai_session_id, "shared-model @ provider-b")
                .await
                .map(|provider| provider.id),
            Some("provider-b".to_string())
        );
    }
}

#[derive(Debug, serde::Deserialize)]
struct RemoteAiSessionResponse {
    id: Uuid,
    terminal_id: Uuid,
}

struct RemoteRegisteredAiSession {
    ai_session_id: Uuid,
    terminal_id: Uuid,
}

async fn try_register_remote_ai_session(
    state: &AppState,
    cwd: &Path,
    cols: u16,
    rows: u16,
    ai_session_id: Uuid,
    terminal_id: Uuid,
    launch: &crate::app::ai::config::AiLaunchConfig,
) -> anyhow::Result<Option<RemoteRegisteredAiSession>> {
    let Some(session) = state.auth_session_store.current_session().await else {
        return Ok(None);
    };
    let client = reqwest::Client::new();
    let url = format!(
        "{}/api/v1/desktop/ai-sessions/local",
        state.config.backend.base_url.trim_end_matches('/')
    );
    let response = client
        .post(url)
        .bearer_auth(session.access_token)
        .json(&serde_json::json!({
            "ai_session_id": ai_session_id,
            "terminal_id": terminal_id,
            "device_id": state.config.backend.device_id,
            "title": format!("Sirix AI · {}", launch.agent.name),
            "shell": "codex",
            "cwd": cwd.display().to_string(),
            "cols": i32::from(cols),
            "rows": i32::from(rows),
            "workspace_root": cwd.display().to_string(),
            "agent_id": launch.agent.id.clone(),
            "model_id": launch.model.id.clone(),
            "entrypoint": "sirix",
        }))
        .send()
        .await
        .context("failed to register local desktop ai session at backend")?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("backend local ai session register failed status={status} body={body}");
    }

    let payload = response
        .json::<RemoteAiSessionResponse>()
        .await
        .context("failed to decode backend local ai session register response")?;
    Ok(Some(RemoteRegisteredAiSession {
        ai_session_id: payload.id,
        terminal_id: payload.terminal_id,
    }))
}
