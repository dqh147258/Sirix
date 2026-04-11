use std::{collections::HashMap, path::Path, sync::Arc};

use anyhow::Context;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::app::{ai::config::SirixConfigStore, state::AppState};

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

#[derive(Debug, Clone, serde::Serialize)]
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
    sessions: Arc<RwLock<HashMap<Uuid, AiSessionRecord>>>,
    terminal_index: Arc<RwLock<HashMap<Uuid, Uuid>>>,
}

impl AiSessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn insert(&self, record: AiSessionRecord) {
        let ai_session_id = record.ai_session_id;
        let terminal_id = record.terminal_id;
        let mut sessions = self.sessions.write().await;
        let mut terminal_index = self.terminal_index.write().await;
        if let Some(previous_ai_session_id) = terminal_index.insert(terminal_id, ai_session_id) {
            sessions.remove(&previous_ai_session_id);
        }
        sessions.insert(ai_session_id, record);
    }

    pub async fn list(&self) -> Vec<AiSessionRecord> {
        let mut items = self
            .sessions
            .read()
            .await
            .values()
            .cloned()
            .collect::<Vec<_>>();
        items.sort_by(|left, right| left.ai_session_id.cmp(&right.ai_session_id));
        items
    }

    pub async fn resolve(&self, any_id: Uuid) -> Option<AiSessionRecord> {
        if let Some(record) = self.sessions.read().await.get(&any_id).cloned() {
            return Some(record);
        }
        let mapped = self.terminal_index.read().await.get(&any_id).copied()?;
        self.sessions.read().await.get(&mapped).cloned()
    }
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
    config_store.write_codex_bridge_config(&launch, cwd)?;
    state
        .terminal_manager
        .create_codex_terminal(terminal_id, launch, cols, rows, mirrored_to_backend)
        .await
        .context("failed to create codex-backed terminal")?;

    state
        .ai_session_registry
        .insert(AiSessionRecord {
            ai_session_id,
            terminal_id,
            cwd: cwd.display().to_string(),
            agent_id: resolved_agent_id,
            model_id: resolved_model_id,
            mirrored_to_backend,
        })
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
    config_store.write_codex_bridge_config(&launch, cwd)?;

    state
        .ai_session_registry
        .insert(AiSessionRecord {
            ai_session_id,
            terminal_id,
            cwd: cwd.display().to_string(),
            agent_id: resolved_agent_id,
            model_id: resolved_model_id,
            mirrored_to_backend: false,
        })
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
            codex_executable: super::super::terminal::manager::resolve_codex_executable(),
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
