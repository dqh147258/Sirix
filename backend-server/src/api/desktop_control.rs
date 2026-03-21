use axum::{
    extract::{Path, State},
    Json,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tracing::info;
use uuid::Uuid;

use crate::{
    api::error::{ApiError, ApiResult},
    application::state::AppState,
    domain::{RequestStatus, ScreenInfo, ScreenSnapshot, SessionState},
};

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DesktopDecision {
    Approve,
    Reject,
}

#[derive(Debug, Deserialize)]
pub struct SessionDecisionRequest {
    pub device_id: Uuid,
    pub decision: DesktopDecision,
    pub reason: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct HeartbeatRequest {
    pub source: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PendingDesktopSessionResponse {
    pub request_id: Uuid,
    pub session_id: Uuid,
    pub requester_user_id: Uuid,
    pub target_device_id: Uuid,
    pub auto_approved: bool,
    pub quality_profile: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ScreenInfoPayload {
    pub screen_id: String,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub is_primary: bool,
}

#[derive(Debug, Deserialize)]
pub struct ScreenSnapshotPayload {
    pub screen_id: String,
    pub width: u32,
    pub height: u32,
    pub preview_base64: String,
    pub captured_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateScreenStateRequest {
    pub source: Option<String>,
    pub snapshot_ttl_seconds: Option<u64>,
    #[serde(default)]
    pub screens: Vec<ScreenInfoPayload>,
    #[serde(default)]
    pub snapshots: Vec<ScreenSnapshotPayload>,
}

pub async fn decide_session(
    State(state): State<AppState>,
    Path(session_id): Path<Uuid>,
    Json(payload): Json<SessionDecisionRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let row = state
        .postgres
        .query_opt(
            "SELECT request_id, requester_user_id, target_device_id, state FROM share_sessions WHERE id = $1",
            &[&session_id],
        )
        .await
        .map_err(internal_error)?;

    let Some(row) = row else {
        return Err(ApiError::not_found(
            "SESSION_NOT_FOUND",
            "session not found",
        ));
    };

    let request_id: Uuid = row.get("request_id");
    let requester_user_id: Uuid = row.get("requester_user_id");
    let target_device_id: Uuid = row.get("target_device_id");
    let current_state_raw: String = row.get("state");
    let current_state = SessionState::from_db(&current_state_raw);

    if target_device_id != payload.device_id {
        return Err(ApiError::forbidden(
            "SESSION_NOT_ACTIVE",
            "device mismatch for this session",
        ));
    }

    let (next_state, next_request_status, db_event, mobile_event_type) = match payload.decision {
        DesktopDecision::Approve => (
            SessionState::Connecting,
            RequestStatus::Accepted,
            "session.approved",
            "connection.request.accepted",
        ),
        DesktopDecision::Reject => (
            SessionState::Terminated,
            RequestStatus::Rejected,
            "session.rejected",
            "connection.request.rejected",
        ),
    };

    if current_state.as_str() == next_state.as_str() {
        return Ok(Json(serde_json::json!({
            "ok": true,
            "applied": false,
            "session_id": session_id,
            "request_id": request_id,
            "state": current_state,
            "request_status": next_request_status,
        })));
    }

    if current_state == SessionState::Terminated
        && matches!(payload.decision, DesktopDecision::Approve)
    {
        return Err(ApiError::conflict(
            "SESSION_DECISION_CONFLICT",
            "terminated session cannot be approved",
        ));
    }

    if !matches!(
        current_state,
        SessionState::Requested | SessionState::PendingApproval
    ) {
        return Err(ApiError::conflict(
            "SESSION_DECISION_CONFLICT",
            format!(
                "session in state '{}' cannot accept decision",
                current_state.as_str()
            ),
        ));
    }

    let now = Utc::now();

    state
        .postgres
        .execute(
            "UPDATE share_sessions SET state = $2, updated_at = $3 WHERE id = $1",
            &[&session_id, &next_state.as_str(), &now],
        )
        .await
        .map_err(internal_error)?;

    state
        .postgres
        .execute(
            "UPDATE connection_requests SET status = $2 WHERE id = $1",
            &[&request_id, &next_request_status.as_str()],
        )
        .await
        .map_err(internal_error)?;

    let event_payload = serde_json::json!({
        "request_id": request_id,
        "decision": payload.decision,
        "reason": payload.reason,
        "state": next_state,
        "request_status": next_request_status,
    });

    state
        .postgres
        .execute(
            "INSERT INTO session_events (session_id, event_type, created_at, payload) VALUES ($1, $2, $3, $4)",
            &[&session_id, &db_event, &now, &event_payload],
        )
        .await
        .map_err(internal_error)?;

    let mobile_payload = serde_json::json!({
        "type": mobile_event_type,
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": now,
        "payload": {
            "request_id": request_id,
            "session_id": session_id,
            "state": next_state,
            "request_status": next_request_status,
            "reason": payload.reason,
            "target_device_id": target_device_id,
        }
    });

    state
        .publish_mobile_event(requester_user_id, mobile_payload.to_string())
        .await;

    Ok(Json(serde_json::json!({
        "ok": true,
        "applied": true,
        "session_id": session_id,
        "request_id": request_id,
        "state": next_state,
        "request_status": next_request_status,
    })))
}

pub async fn heartbeat(
    State(state): State<AppState>,
    Path(device_id): Path<Uuid>,
    Json(payload): Json<HeartbeatRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    state
        .touch_last_seen(device_id)
        .await
        .map_err(internal_error)?;

    Ok(Json(serde_json::json!({
        "ok": true,
        "device_id": device_id,
        "source": payload.source,
        "logging_enabled": state.runtime_settings.logging_enabled,
        "server_time": Utc::now(),
    })))
}

pub async fn list_pending_sessions(
    State(state): State<AppState>,
    Path(device_id): Path<Uuid>,
) -> ApiResult<Json<Vec<PendingDesktopSessionResponse>>> {
    let rows = state
        .postgres
        .query(
            "SELECT id, request_id, requester_user_id, target_device_id, quality_profile FROM share_sessions WHERE target_device_id = $1 AND state IN ('requested', 'pending_approval') ORDER BY created_at ASC LIMIT 32",
            &[&device_id],
        )
        .await
        .map_err(internal_error)?;

    let sessions = rows
        .into_iter()
        .map(|row| PendingDesktopSessionResponse {
            request_id: row.get("request_id"),
            session_id: row.get("id"),
            requester_user_id: row.get("requester_user_id"),
            target_device_id: row.get("target_device_id"),
            auto_approved: false,
            quality_profile: row.get("quality_profile"),
        })
        .collect::<Vec<_>>();

    Ok(Json(sessions))
}

pub async fn update_screen_state(
    State(state): State<AppState>,
    Path(device_id): Path<Uuid>,
    Json(payload): Json<UpdateScreenStateRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let exists = state
        .postgres
        .query_opt("SELECT 1 FROM devices WHERE id = $1", &[&device_id])
        .await
        .map_err(internal_error)?;

    if exists.is_none() {
        return Err(ApiError::not_found("DEVICE_NOT_FOUND", "device not found"));
    }

    let now = Utc::now();

    let screens = payload
        .screens
        .into_iter()
        .map(|screen| ScreenInfo {
            screen_id: screen.screen_id,
            name: screen.name,
            width: screen.width.max(1),
            height: screen.height.max(1),
            is_primary: screen.is_primary,
        })
        .collect::<Vec<_>>();

    let snapshots_from_payload = payload
        .snapshots
        .into_iter()
        .map(|snapshot| ScreenSnapshot {
            screen_id: snapshot.screen_id,
            captured_at: snapshot.captured_at.unwrap_or(now),
            width: snapshot.width.max(1),
            height: snapshot.height.max(1),
            preview_base64: snapshot.preview_base64,
        })
        .collect::<Vec<_>>();

    let snapshots = if snapshots_from_payload.is_empty() {
        screens
            .iter()
            .map(|screen| {
                let preview_width = 480u32;
                let ratio = (screen.width as f64 / screen.height as f64).max(1.0);
                let preview_height = ((preview_width as f64) / ratio).round().max(120.0) as u32;
                ScreenSnapshot {
                    screen_id: screen.screen_id.clone(),
                    captured_at: now,
                    width: preview_width,
                    height: preview_height,
                    preview_base64: String::new(),
                }
            })
            .collect::<Vec<_>>()
    } else {
        snapshots_from_payload
    };

    state
        .cache_screens(device_id, &screens)
        .await
        .map_err(internal_error)?;

    let ttl_seconds = payload.snapshot_ttl_seconds.unwrap_or(300).clamp(30, 1800) as usize;
    state
        .cache_snapshots(device_id, &snapshots, ttl_seconds)
        .await
        .map_err(internal_error)?;

    state
        .touch_last_seen(device_id)
        .await
        .map_err(internal_error)?;

    info!(
        device_id = %device_id,
        screen_count = screens.len(),
        snapshot_count = snapshots.len(),
        source = ?payload.source,
        "desktop screen state updated"
    );

    Ok(Json(serde_json::json!({
        "ok": true,
        "device_id": device_id,
        "screen_count": screens.len(),
        "snapshot_count": snapshots.len(),
        "snapshot_ttl_seconds": ttl_seconds,
    })))
}

fn internal_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal(
        "DESKTOP_CONTROL_INTERNAL",
        format!("desktop control internal error: {error}"),
    )
}
