use std::path::PathBuf;

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;

use crate::app::{
    ai::{
        approval::{ApprovalDecision, ApprovalRecord, ApprovalScope},
        config::{validate_sirix_config, ApprovalMode, SirixConfig},
        session::{launch_ai_session, AiSessionLaunchResponse, AiSessionRecord},
    },
    state::AppState,
};

#[derive(Debug, Deserialize)]
pub struct EffectiveConfigQuery {
    pub cwd: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ResolveSessionQuery {
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct LaunchAiSessionRequest {
    pub cwd: Option<String>,
    pub agent_id: Option<String>,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
}

#[derive(Debug, Deserialize)]
pub struct CheckApprovalRequest {
    pub session_id: String,
    pub capability_key: String,
}

#[derive(Debug, Deserialize)]
pub struct ResolveApprovalRequest {
    pub session_id: String,
    pub capability_key: String,
    pub decision: ApprovalDecision,
    pub scope: ApprovalScope,
}

#[derive(Debug, serde::Serialize)]
pub struct CheckApprovalResponse {
    pub outcome: String,
    pub configured_mode: ApprovalMode,
    pub cached: bool,
}

pub async fn get_ai_config(State(state): State<AppState>) -> Result<Json<SirixConfig>, ApiError> {
    let config = state
        .sirix_config_store
        .load_global()
        .map_err(ApiError::internal)?;
    Ok(Json(config))
}

pub async fn set_ai_config(
    State(state): State<AppState>,
    Json(payload): Json<SirixConfig>,
) -> Result<Json<SirixConfig>, ApiError> {
    validate_sirix_config(&payload).map_err(ApiError::bad_request_anyhow)?;
    state
        .sirix_config_store
        .save_global(&payload)
        .map_err(ApiError::internal)?;
    Ok(Json(payload))
}

pub async fn get_effective_ai_config(
    State(state): State<AppState>,
    Query(query): Query<EffectiveConfigQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let effective = state
        .sirix_config_store
        .effective_for_workspace(query.cwd.as_deref())
        .map_err(ApiError::internal)?;
    Ok(Json(
        serde_json::to_value(effective)
            .map_err(|error| ApiError::internal(error.into()))?,
    ))
}

pub async fn launch_session(
    State(state): State<AppState>,
    Json(payload): Json<LaunchAiSessionRequest>,
) -> Result<Json<AiSessionLaunchResponse>, ApiError> {
    let cwd = payload
        .cwd
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    let response = launch_ai_session(
        &state,
        state.sirix_config_store.as_ref(),
        cwd.as_path(),
        payload.agent_id.as_deref(),
        payload.cols.unwrap_or(120).clamp(20, 400),
        payload.rows.unwrap_or(32).clamp(10, 200),
    )
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn list_sessions(
    State(state): State<AppState>,
) -> Result<Json<Vec<AiSessionRecord>>, ApiError> {
    Ok(Json(state.ai_session_registry.list().await))
}

pub async fn resolve_session(
    State(state): State<AppState>,
    Query(query): Query<ResolveSessionQuery>,
) -> Result<Json<AiSessionRecord>, ApiError> {
    let session_id =
        uuid::Uuid::parse_str(&query.id).map_err(|error| ApiError::bad_request(error.to_string()))?;
    let Some(record) = state.ai_session_registry.resolve(session_id).await else {
        return Err(ApiError::not_found(format!(
            "ai session not found for id={}",
            query.id
        )));
    };
    Ok(Json(record))
}

pub async fn check_approval(
    State(state): State<AppState>,
    Json(payload): Json<CheckApprovalRequest>,
) -> Result<Json<CheckApprovalResponse>, ApiError> {
    let session_id = uuid::Uuid::parse_str(payload.session_id.trim())
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let capability_key = payload.capability_key.trim();
    if capability_key.is_empty() {
        return Err(ApiError::bad_request("capability_key cannot be empty".to_string()));
    }

    let Some(record) = state.ai_session_registry.resolve(session_id).await else {
        return Err(ApiError::not_found(format!(
            "ai session not found for id={}",
            payload.session_id
        )));
    };

    if let Some(cached) = state
        .ai_approval_registry
        .resolve_for_check(record.ai_session_id, capability_key)
        .await
    {
        let outcome = match cached.decision {
            ApprovalDecision::Allow => "allow",
            ApprovalDecision::Deny => "deny",
        };
        return Ok(Json(CheckApprovalResponse {
            outcome: outcome.to_string(),
            configured_mode: ApprovalMode::Allow,
            cached: true,
        }));
    }

    let configured_mode = resolve_capability_mode(
        state.sirix_config_store.as_ref(),
        &record.cwd,
        &record.agent_id,
        capability_key,
    )
    .map_err(ApiError::internal)?;
    let outcome = match configured_mode {
        ApprovalMode::Allow => "allow",
        ApprovalMode::Deny => "deny",
        ApprovalMode::AskOnce | ApprovalMode::AskEachTime => {
            emit_approval_request_event(
                &state,
                &record,
                capability_key,
                configured_mode.clone(),
            )
            .await;
            "ask"
        }
    };
    Ok(Json(CheckApprovalResponse {
        outcome: outcome.to_string(),
        configured_mode,
        cached: false,
    }))
}

pub async fn resolve_approval(
    State(state): State<AppState>,
    Json(payload): Json<ResolveApprovalRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let session_id = uuid::Uuid::parse_str(payload.session_id.trim())
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let capability_key = payload.capability_key.trim().to_string();
    if capability_key.is_empty() {
        return Err(ApiError::bad_request("capability_key cannot be empty".to_string()));
    }
    let Some(record) = state.ai_session_registry.resolve(session_id).await else {
        return Err(ApiError::not_found(format!(
            "ai session not found for id={}",
            payload.session_id
        )));
    };

    state
        .ai_approval_registry
        .set(
            record.ai_session_id,
            capability_key.clone(),
            ApprovalRecord {
                decision: payload.decision,
                scope: payload.scope,
            },
        )
        .await;
    state
        .ai_approval_registry
        .clear_pending(record.ai_session_id, &capability_key)
        .await;

    if record.mirrored_to_backend {
        sync_approval_to_backend(
            &state,
            record.ai_session_id,
            &capability_key,
            payload.decision,
            payload.scope,
        )
        .await
        .map_err(ApiError::internal)?;
    }

    let _ = state.local_events.send(
        serde_json::json!({
            "type": "ai.approval.resolved",
            "payload": {
                "ai_session_id": record.ai_session_id,
                "terminal_id": record.terminal_id,
                "capability_key": capability_key,
                "decision": match payload.decision {
                    ApprovalDecision::Allow => "allow",
                    ApprovalDecision::Deny => "deny",
                },
                "scope": match payload.scope {
                    ApprovalScope::Once => "once",
                    ApprovalScope::Session => "session",
                    ApprovalScope::Deny => "deny",
                },
            }
        })
        .to_string(),
    );

    Ok(Json(serde_json::json!({"ok": true})))
}

pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: String) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message,
        }
    }

    fn bad_request_anyhow(error: anyhow::Error) -> Self {
        Self::bad_request(error.to_string())
    }

    fn not_found(message: String) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message,
        }
    }

    fn internal(error: anyhow::Error) -> Self {
        Self {
            status: StatusCode::BAD_GATEWAY,
            message: error.to_string(),
        }
    }
}

fn resolve_capability_mode(
    store: &crate::app::ai::config::SirixConfigStore,
    cwd: &str,
    agent_id: &str,
    capability_key: &str,
) -> anyhow::Result<ApprovalMode> {
    let config = store.effective_for_workspace(Some(cwd))?.config;
    let agent = config
        .agents
        .iter()
        .find(|item| item.id == agent_id)
        .cloned();
    let Some(agent) = agent else {
        return Ok(ApprovalMode::Allow);
    };

    for rule in &agent.capability_rules {
        if rule.key == capability_key {
            return Ok(rule.approval_mode.clone());
        }
    }
    Ok(ApprovalMode::Allow)
}

async fn emit_approval_request_event(
    state: &AppState,
    record: &AiSessionRecord,
    capability_key: &str,
    configured_mode: ApprovalMode,
) {
    if !state
        .ai_approval_registry
        .mark_pending(record.ai_session_id, capability_key)
        .await
    {
        return;
    }

    let _ = state.local_events.send(
        serde_json::json!({
            "type": "ai.approval.request",
            "payload": {
                "ai_session_id": record.ai_session_id,
                "terminal_id": record.terminal_id,
                "cwd": record.cwd,
                "agent_id": record.agent_id,
                "model_id": record.model_id,
                "capability_key": capability_key,
                "configured_mode": configured_mode,
            }
        })
        .to_string(),
    );
}

async fn sync_approval_to_backend(
    state: &AppState,
    ai_session_id: uuid::Uuid,
    capability_key: &str,
    decision: ApprovalDecision,
    scope: ApprovalScope,
) -> anyhow::Result<()> {
    let Some(session) = state.auth_session_store.current_session().await else {
        return Ok(());
    };
    let url = format!(
        "{}/api/v1/ai-sessions/{}/approvals",
        state.config.backend.base_url.trim_end_matches('/'),
        ai_session_id
    );
    reqwest::Client::new()
        .post(url)
        .bearer_auth(session.access_token)
        .json(&serde_json::json!({
            "capability_key": capability_key,
            "decision": match decision {
                ApprovalDecision::Allow => "allow",
                ApprovalDecision::Deny => "deny",
            },
            "scope": match scope {
                ApprovalScope::Once => "once",
                ApprovalScope::Session => "session",
                ApprovalScope::Deny => "deny",
            },
        }))
        .send()
        .await?
        .error_for_status()?;
    Ok(())
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (
            self.status,
            Json(serde_json::json!({
                "error": self.message,
            })),
        )
            .into_response()
    }
}
