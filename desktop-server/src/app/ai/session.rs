use std::{collections::HashMap, path::Path, sync::Arc};

use anyhow::Context;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::app::{
    ai::config::{ProviderConfig, SirixConfigStore},
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
}

impl AiSessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn insert(
        &self,
        record: AiSessionRecord,
        active_provider: ProviderConfig,
        session_providers: Vec<ProviderConfig>,
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
                active_provider_id: active_provider.id,
                providers: session_providers,
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

fn resolve_provider_for_model(
    routing: &SessionProviderRouting,
    model_id: &str,
) -> Option<ProviderConfig> {
    let trimmed_model_id = model_id.trim();
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
    let resolved_provider = launch.provider.clone();
    let session_providers = launch.session_providers.clone();
    let runtime = state.runtime.read().await;
    let local_ws_port = runtime.local_ws_port;
    drop(runtime);
    config_store.write_codex_bridge_config(&launch, cwd, local_ws_port, ai_session_id)?;
    state
        .terminal_manager
        .create_codex_terminal(terminal_id, launch, cols, rows, mirrored_to_backend)
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
            resolved_provider,
            session_providers,
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
    let session_providers = launch.session_providers.clone();
    let runtime = state.runtime.read().await;
    let local_ws_port = runtime.local_ws_port;
    drop(runtime);
    config_store.write_codex_bridge_config(&launch, cwd, local_ws_port, ai_session_id)?;

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
            launch.provider.clone(),
            session_providers,
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
    use crate::app::ai::config::{ModelConfig, ModelKind, ProviderKind};

    fn test_provider(id: &str) -> ProviderConfig {
        ProviderConfig {
            id: id.to_string(),
            name: id.to_string(),
            kind: ProviderKind::OpenAiCompatible,
            base_url: "https://example.com/v1".to_string(),
            api_key_env: "TEST_API_KEY".to_string(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![ModelConfig {
                id: "model".to_string(),
                display_name: "Model".to_string(),
                model_kind: ModelKind::Text,
                context_window: 32_000,
                supports_images: false,
                enabled: true,
            }],
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
                test_provider("provider-a"),
                vec![test_provider("provider-a")],
            )
            .await;
        registry
            .insert(
                second.clone(),
                test_provider("provider-b"),
                vec![test_provider("provider-b")],
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
                test_provider("provider-b"),
                vec![test_provider("provider-a"), test_provider("provider-b")],
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
