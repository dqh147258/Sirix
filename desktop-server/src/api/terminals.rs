use std::path::PathBuf;

use anyhow::Context;
use axum::{extract::State, Json};
use reqwest::header::AUTHORIZATION;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::app::state::AppState;

use super::ai::ApiError;

#[derive(Debug, Deserialize)]
pub struct CreateHostedTerminalSessionRequest {
    pub cwd: Option<String>,
    pub shell: Option<String>,
    pub title: Option<String>,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
}

#[derive(Debug, Serialize)]
pub struct CreateHostedTerminalSessionResponse {
    pub terminal_id: Uuid,
    pub host_token: String,
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

pub async fn create_hosted_terminal_session(
    State(state): State<AppState>,
    Json(payload): Json<CreateHostedTerminalSessionRequest>,
) -> Result<Json<CreateHostedTerminalSessionResponse>, ApiError> {
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
                "failed to create remote hosted terminal session, falling back to local-only: {error}"
            ));
            (Uuid::new_v4(), false)
        }
    };
    let response = state
        .terminal_manager
        .create_hosted_terminal(
            terminal_id,
            shell.clone(),
            cwd.clone(),
            title.clone(),
            cols,
            rows,
            mirrored_to_backend,
        )
        .await
        .map(|session| {
            Json(CreateHostedTerminalSessionResponse {
                terminal_id: session.terminal_id,
                host_token: session.host_token,
                mirrored_to_backend: session.remote_sync,
            })
        })
        .map_err(ApiError::internal)?;

    Ok(response)
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

    // Hosted terminals reuse the existing backend terminal session pipeline so
    // Desktop/Mobile observers stay on the same websocket/event model as every
    // other shared terminal entry point.
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
