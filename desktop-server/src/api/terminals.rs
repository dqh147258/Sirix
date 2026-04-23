use std::path::PathBuf;

use anyhow::Context;
use axum::{
    extract::{Path, State},
    Json,
};
use reqwest::header::AUTHORIZATION;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::app::state::AppState;

use super::ai::ApiError;

#[derive(Debug, Deserialize)]
pub struct CreateTerminalSessionRequest {
    pub cwd: Option<String>,
    pub shell: Option<String>,
    pub title: Option<String>,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
}

#[derive(Debug, Serialize)]
pub struct CreateLocalTerminalSessionResponse {
    pub terminal_id: Uuid,
    pub mirrored_to_backend: bool,
}

#[derive(Debug, Deserialize)]
struct BackendCreateLocalTerminalResponse {
    id: Uuid,
}

#[derive(Debug, Serialize)]
struct BackendCreateLocalTerminalRequest<'a> {
    device_id: Uuid,
    title: &'a str,
    shell: &'a str,
    cwd: &'a str,
    cols: i32,
    rows: i32,
}

pub async fn create_local_terminal_session(
    State(state): State<AppState>,
    Json(payload): Json<CreateTerminalSessionRequest>,
) -> Result<Json<CreateLocalTerminalSessionResponse>, ApiError> {
    let cwd = payload
        .cwd
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .display()
                .to_string()
        });
    let shell = payload
        .shell
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "default".to_string());
    let title = payload
        .title
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "Sirix Terminal".to_string());
    let cols = payload.cols.unwrap_or(120).clamp(20, 400);
    let rows = payload.rows.unwrap_or(32).clamp(10, 200);

    let (terminal_id, mirrored_to_backend) = match create_remote_terminal_if_available(
        &state,
        title.as_str(),
        shell.as_str(),
        cwd.as_str(),
        cols,
        rows,
    )
    .await
    {
        Ok(Some(id)) => (id, true),
        Ok(None) => (Uuid::new_v4(), false),
        Err(error) => {
            state.logger.warn(format!(
                "failed to create remote terminal session row, falling back to local-only runtime: {error}"
            ));
            (Uuid::new_v4(), false)
        }
    };

    let prefer_tmux_terminal = state.runtime.read().await.prefer_tmux_terminal;
    if let Err(error) = state
        .terminal_manager
        .create_terminal(
            terminal_id,
            Some(shell.clone()),
            Some(cwd.clone()),
            Some(title.clone()),
            cols,
            rows,
            prefer_tmux_terminal,
            mirrored_to_backend,
        )
        .await
    {
        if mirrored_to_backend {
            if let Err(mark_error) =
                mark_remote_terminal_error(&state, terminal_id, error.to_string()).await
            {
                state.logger.warn(format!(
                    "failed to mark remote terminal as error after local runtime create failure terminal_id={} error={mark_error}",
                    terminal_id
                ));
            }
        }
        return Err(ApiError::internal(error));
    }

    Ok(Json(CreateLocalTerminalSessionResponse {
        terminal_id,
        mirrored_to_backend,
    }))
}

pub async fn close_local_terminal_session(
    State(state): State<AppState>,
    Path(terminal_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    state
        .terminal_manager
        .close(terminal_id)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(serde_json::json!({ "ok": true })))
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

async fn create_remote_terminal_if_available(
    state: &AppState,
    title: &str,
    shell: &str,
    cwd: &str,
    cols: u16,
    rows: u16,
) -> anyhow::Result<Option<Uuid>> {
    if !remote_sync_available(state).await {
        return Ok(None);
    }

    let Some(session) = state.auth_session_store.current_session().await else {
        return Ok(None);
    };
    let device_id = Uuid::parse_str(state.config.backend.device_id.trim())
        .context("desktop device id is not a valid UUID")?;
    let url = format!(
        "{}/api/v1/desktop/terminals/local",
        state.config.backend.base_url.trim_end_matches('/')
    );

    let payload = BackendCreateLocalTerminalRequest {
        device_id,
        title,
        shell,
        cwd,
        cols: i32::from(cols),
        rows: i32::from(rows),
    };
    let response = reqwest::Client::new()
        .post(url)
        .header(
            AUTHORIZATION,
            format!("Bearer {}", session.access_token.trim()),
        )
        .json(&payload)
        .send()
        .await?
        .error_for_status()?;
    let created = response
        .json::<BackendCreateLocalTerminalResponse>()
        .await
        .context("failed to decode remote terminal response")?;
    Ok(Some(created.id))
}

async fn mark_remote_terminal_error(
    state: &AppState,
    terminal_id: Uuid,
    error_message: String,
) -> anyhow::Result<()> {
    let Some(session) = state.auth_session_store.current_session().await else {
        anyhow::bail!("no local auth session available for remote terminal error sync");
    };
    let device_id = Uuid::parse_str(state.config.backend.device_id.trim())
        .context("desktop device id is not a valid UUID")?;
    let url = format!(
        "{}/api/v1/desktop/terminals/{terminal_id}/state",
        state.config.backend.base_url.trim_end_matches('/')
    );

    reqwest::Client::new()
        .post(url)
        .header(
            AUTHORIZATION,
            format!("Bearer {}", session.access_token.trim()),
        )
        .json(&serde_json::json!({
            "device_id": device_id,
            "state": "error",
            "error_message": error_message,
        }))
        .send()
        .await?
        .error_for_status()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bootstrap::config::{
        AppConfig, AuthorizationConfig, BackendConfig, CaptureConfig, LocalWsConfig, LoggingConfig,
        StreamConfig,
    };
    use axum::{body::to_bytes, extract::State, response::IntoResponse, Json};

    fn test_state() -> AppState {
        AppState::new(
            AppConfig {
                backend: BackendConfig {
                    base_url: "http://127.0.0.1:3000".to_string(),
                    health_path: "/health".to_string(),
                    heartbeat_path: "/heartbeat".to_string(),
                    heartbeat_interval_seconds: 30,
                    device_id: Uuid::new_v4().to_string(),
                    event_ws_path: "/events".to_string(),
                    session_decision_path: "/session-decision".to_string(),
                    webrtc_signal_path: "/webrtc".to_string(),
                    runtime_settings_path: "/runtime-settings".to_string(),
                    runtime_logs_path: "/runtime-logs".to_string(),
                    pending_sessions_path: "/pending-sessions".to_string(),
                    screen_state_path: "/screen-state".to_string(),
                },
                local_ws: LocalWsConfig {
                    host: "127.0.0.1".to_string(),
                    port_range_start: 18080,
                    port_range_end: 18090,
                },
                authorization: AuthorizationConfig::default(),
                capture: CaptureConfig {
                    snapshot_interval_seconds: 5,
                    snapshot_width: 1280,
                },
                stream: StreamConfig {
                    default_profile: "balanced".to_string(),
                    default_fps: 15,
                    auto_adapt: true,
                },
                logging: LoggingConfig {
                    level: "info".to_string(),
                    json: false,
                },
            },
            18080,
        )
    }

    #[tokio::test]
    async fn create_local_terminal_session_creates_server_owned_runtime_when_remote_sync_is_unavailable(
    ) {
        let state = test_state();
        let cwd = std::env::temp_dir().display().to_string();

        let result = create_local_terminal_session(
            State(state.clone()),
            Json(CreateTerminalSessionRequest {
                cwd: Some(cwd),
                shell: Some(
                    if cfg!(target_os = "windows") {
                        "cmd.exe"
                    } else {
                        "/bin/sh"
                    }
                    .to_string(),
                ),
                title: Some("Sirix Terminal".to_string()),
                cols: Some(100),
                rows: Some(30),
            }),
        )
        .await;
        let Json(response) = match result {
            Ok(response) => response,
            Err(error) => {
                let response = error.into_response();
                let status = response.status();
                let body = to_bytes(response.into_body(), usize::MAX)
                    .await
                    .expect("api error body should decode");
                panic!(
                    "local terminal session should be created status={} body={}",
                    status,
                    String::from_utf8_lossy(&body)
                );
            }
        };

        assert!(
            !response.mirrored_to_backend,
            "test state should stay local-only when no auth/backend sync is available"
        );

        let snapshot = state
            .terminal_manager
            .get_snapshot(response.terminal_id)
            .await
            .expect("server-owned local runtime should exist");
        assert_eq!(snapshot.source, "local_pty");
        assert_eq!(snapshot.state, "active");

        state
            .terminal_manager
            .close(response.terminal_id)
            .await
            .expect("test runtime should close cleanly");
    }
}
