use axum::{
    extract::{Path, State},
    Json,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    api::error::{ApiError, ApiResult},
    application::state::AppState,
    domain::{RequestStatus, SessionState},
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
        "server_time": Utc::now(),
    })))
}

fn internal_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal(
        "DESKTOP_CONTROL_INTERNAL",
        format!("desktop control internal error: {error}"),
    )
}
