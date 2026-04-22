use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    api::{
        error::{ApiError, ApiResult},
        resolve_user_id,
    },
    application::state::AppState,
};

#[derive(Debug, Serialize)]
pub struct AiSessionSummary {
    pub id: Uuid,
    pub terminal_id: Uuid,
    pub device_id: Uuid,
    pub workspace_root: String,
    pub agent_id: String,
    pub model_id: String,
    pub status: String,
    pub entrypoint: String,
    pub created_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
pub struct ListAiSessionQuery {
    pub device_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
pub struct CreateLocalDesktopAiSessionRequest {
    pub device_id: Uuid,
    pub title: Option<String>,
    pub shell: Option<String>,
    pub cwd: Option<String>,
    pub cols: i32,
    pub rows: i32,
    pub workspace_root: String,
    pub agent_id: String,
    pub model_id: String,
    pub entrypoint: Option<String>,
    pub ai_session_id: Option<Uuid>,
    pub terminal_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
pub struct CreateAiApprovalRequest {
    pub capability_key: String,
    pub decision: String,
    pub scope: String,
}

#[derive(Debug, Deserialize)]
pub struct CreateAiApprovalEventRequest {
    pub request_id: String,
    pub agent_id: String,
    pub model_id: Option<String>,
    pub capability_key: String,
    pub configured_mode: String,
    #[serde(default)]
    pub supported_scopes: Vec<String>,
    pub approval_kind: Option<String>,
    pub shell_command: Option<String>,
    #[serde(default)]
    pub shell_prefix_candidates: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct ResolveAiApprovalRequest {
    pub request_id: Option<String>,
    pub capability_key: String,
    pub agent_id: String,
    pub decision: String,
    pub scope: String,
    pub prefix: Option<String>,
    pub approval_kind: Option<String>,
}

pub async fn create_local_desktop_ai_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateLocalDesktopAiSessionRequest>,
) -> ApiResult<Json<AiSessionSummary>> {
    let user_id = resolve_user_id(&headers, &state).await?;
    let target_row = state
        .postgres
        .query_opt(
            "SELECT user_id FROM devices WHERE id = $1",
            &[&payload.device_id],
        )
        .await
        .map_err(internal_error)?;

    let Some(target_row) = target_row else {
        return Err(ApiError::not_found(
            "DEVICE_NOT_FOUND",
            "target device not found",
        ));
    };

    let owner_id: Uuid = target_row.get("user_id");
    if owner_id != user_id {
        return Err(ApiError::forbidden(
            "DEVICE_NOT_OWNED",
            "current mvp allows only same-account devices",
        ));
    }

    let ai_session_id = payload.ai_session_id.unwrap_or_else(Uuid::new_v4);
    let terminal_id = payload.terminal_id.unwrap_or_else(Uuid::new_v4);
    let now = Utc::now();
    let title = payload
        .title
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "Sirix AI".to_string());
    let shell = payload
        .shell
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "codex".to_string());
    let cwd = payload
        .cwd
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "~".to_string());
    let cols = payload.cols.clamp(20, 400);
    let rows = payload.rows.clamp(10, 200);
    let entrypoint = payload
        .entrypoint
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "sirix".to_string());

    state
        .postgres
        .execute(
            "INSERT INTO terminal_sessions (id, device_id, creator_user_id, title, shell, cwd, state, cols, rows, created_at, updated_at, closed_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
            &[
                &terminal_id,
                &payload.device_id,
                &user_id,
                &title,
                &shell,
                &cwd,
                &"opening",
                &cols,
                &rows,
                &now,
                &now,
                &Option::<DateTime<Utc>>::None,
            ],
        )
        .await
        .map_err(internal_error)?;

    state
        .postgres
        .execute(
            "INSERT INTO terminal_session_participants (session_id, user_id, client_type, joined_at) VALUES ($1,$2,$3,$4)",
            &[&terminal_id, &user_id, &"desktop_local_ai", &now],
        )
        .await
        .map_err(internal_error)?;

    state
        .postgres
        .execute(
            "INSERT INTO ai_sessions (id, device_id, creator_user_id, terminal_id, workspace_root, agent_id, model_id, status, entrypoint, created_at, updated_at, closed_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
            &[
                &ai_session_id,
                &payload.device_id,
                &user_id,
                &terminal_id,
                &payload.workspace_root,
                &payload.agent_id,
                &payload.model_id,
                &"active",
                &entrypoint,
                &now,
                &now,
                &Option::<DateTime<Utc>>::None,
            ],
        )
        .await
        .map_err(internal_error)?;

    state
        .postgres
        .execute(
            "INSERT INTO ai_session_participants (session_id, participant_type, client_instance_id, joined_at) VALUES ($1,$2,$3,$4)",
            &[&ai_session_id, &"desktop_local", &None::<String>, &now],
        )
        .await
        .map_err(internal_error)?;

    Ok(Json(AiSessionSummary {
        id: ai_session_id,
        terminal_id,
        device_id: payload.device_id,
        workspace_root: payload.workspace_root,
        agent_id: payload.agent_id,
        model_id: payload.model_id,
        status: "active".to_string(),
        entrypoint,
        created_at: now,
        closed_at: None,
    }))
}

pub async fn list_ai_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ListAiSessionQuery>,
) -> ApiResult<Json<Vec<AiSessionSummary>>> {
    let user_id = resolve_user_id(&headers, &state).await?;
    let rows = match query.device_id {
        Some(device_id) => {
            state
                .postgres
                .query(
                    "SELECT a.id, a.terminal_id, a.device_id, a.workspace_root, a.agent_id, a.model_id, a.status, a.entrypoint, a.created_at, a.closed_at
                     FROM ai_sessions a
                     JOIN devices d ON d.id = a.device_id
                     WHERE d.user_id = $1 AND a.device_id = $2 AND a.status <> 'closed'
                     ORDER BY a.created_at ASC",
                    &[&user_id, &device_id],
                )
                .await
        }
        None => {
            state
                .postgres
                .query(
                    "SELECT a.id, a.terminal_id, a.device_id, a.workspace_root, a.agent_id, a.model_id, a.status, a.entrypoint, a.created_at, a.closed_at
                     FROM ai_sessions a
                     JOIN devices d ON d.id = a.device_id
                     WHERE d.user_id = $1 AND a.status <> 'closed'
                     ORDER BY a.created_at ASC",
                    &[&user_id],
                )
                .await
        }
    }
    .map_err(internal_error)?;

    Ok(Json(
        rows.into_iter()
            .map(|row| AiSessionSummary {
                id: row.get("id"),
                terminal_id: row.get("terminal_id"),
                device_id: row.get("device_id"),
                workspace_root: row.get("workspace_root"),
                agent_id: row.get("agent_id"),
                model_id: row.get("model_id"),
                status: row.get("status"),
                entrypoint: row.get("entrypoint"),
                created_at: row.get("created_at"),
                closed_at: row.get("closed_at"),
            })
            .collect::<Vec<_>>(),
    ))
}

pub async fn create_ai_approval(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(ai_session_id): Path<Uuid>,
    Json(payload): Json<CreateAiApprovalRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let user_id = resolve_user_id(&headers, &state).await?;
    let owner = state
        .postgres
        .query_opt(
            "SELECT d.user_id FROM ai_sessions a JOIN devices d ON d.id = a.device_id WHERE a.id = $1",
            &[&ai_session_id],
        )
        .await
        .map_err(internal_error)?;
    let Some(owner) = owner else {
        return Err(ApiError::not_found(
            "AI_SESSION_NOT_FOUND",
            "ai session not found",
        ));
    };
    let owner_id: Uuid = owner.get("user_id");
    if owner_id != user_id {
        return Err(ApiError::forbidden(
            "AI_SESSION_FORBIDDEN",
            "ai session not owned by current user",
        ));
    }

    let now = Utc::now();
    state
        .postgres
        .execute(
            "INSERT INTO ai_session_approvals (session_id, capability_key, decision, scope, created_at) VALUES ($1,$2,$3,$4,$5)",
            &[&ai_session_id, &payload.capability_key, &payload.decision, &payload.scope, &now],
        )
        .await
        .map_err(internal_error)?;

    Ok(Json(serde_json::json!({"ok": true})))
}

pub async fn create_ai_approval_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(ai_session_id): Path<Uuid>,
    Json(payload): Json<CreateAiApprovalEventRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let (owner_id, device_id, terminal_id) =
        resolve_owned_ai_session(&state, &headers, ai_session_id).await?;
    let event = serde_json::json!({
            "type": "ai.approval.request",
        "payload": {
            "ai_session_id": ai_session_id,
            "terminal_id": terminal_id,
            "request_id": payload.request_id,
            "agent_id": payload.agent_id,
            "model_id": payload.model_id,
            "capability_key": payload.capability_key,
            "configured_mode": payload.configured_mode,
            "supported_scopes": payload.supported_scopes,
            "approval_kind": payload.approval_kind,
            "shell_command": payload.shell_command,
            "shell_prefix_candidates": payload.shell_prefix_candidates,
        }
    });
    state
        .publish_terminal_event(terminal_id, event.to_string())
        .await;
    state
        .publish_desktop_event(device_id, event.to_string())
        .await;
    state
        .publish_mobile_event(owner_id, event.to_string())
        .await;
    Ok(Json(serde_json::json!({"ok": true})))
}

pub async fn resolve_ai_approval(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(ai_session_id): Path<Uuid>,
    Json(payload): Json<ResolveAiApprovalRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let (owner_id, device_id, terminal_id) =
        resolve_owned_ai_session(&state, &headers, ai_session_id).await?;
    let now = Utc::now();
    state
        .postgres
        .execute(
            "INSERT INTO ai_session_approvals (session_id, capability_key, decision, scope, created_at) VALUES ($1,$2,$3,$4,$5)",
            &[&ai_session_id, &payload.capability_key, &payload.decision, &payload.scope, &now],
        )
        .await
        .map_err(internal_error)?;

    let event = serde_json::json!({
            "type": "ai.approval.resolved",
        "payload": {
            "ai_session_id": ai_session_id,
            "terminal_id": terminal_id,
            "request_id": payload.request_id,
            "agent_id": payload.agent_id,
            "capability_key": payload.capability_key,
            "decision": payload.decision,
            "scope": payload.scope,
            "prefix": payload.prefix,
            "approval_kind": payload.approval_kind,
        }
    });
    state
        .publish_terminal_event(terminal_id, event.to_string())
        .await;
    state
        .publish_desktop_event(device_id, event.to_string())
        .await;
    state
        .publish_mobile_event(owner_id, event.to_string())
        .await;
    Ok(Json(serde_json::json!({"ok": true})))
}

async fn resolve_owned_ai_session(
    state: &AppState,
    headers: &HeaderMap,
    ai_session_id: Uuid,
) -> ApiResult<(Uuid, Uuid, Uuid)> {
    let user_id = resolve_user_id(headers, state).await?;
    let row = state
        .postgres
        .query_opt(
            "SELECT d.user_id, a.device_id, a.terminal_id FROM ai_sessions a JOIN devices d ON d.id = a.device_id WHERE a.id = $1",
            &[&ai_session_id],
        )
        .await
        .map_err(internal_error)?;
    let Some(row) = row else {
        return Err(ApiError::not_found(
            "AI_SESSION_NOT_FOUND",
            "ai session not found",
        ));
    };
    let owner_id: Uuid = row.get("user_id");
    if owner_id != user_id {
        return Err(ApiError::forbidden(
            "AI_SESSION_FORBIDDEN",
            "ai session not owned by current user",
        ));
    }
    Ok((owner_id, row.get("device_id"), row.get("terminal_id")))
}

fn internal_error(error: tokio_postgres::Error) -> ApiError {
    ApiError::internal("AI_SESSION_INTERNAL", error.to_string())
}
