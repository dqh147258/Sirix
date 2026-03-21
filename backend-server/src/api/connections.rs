use axum::{extract::State, http::HeaderMap, Json};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};
use uuid::Uuid;

use crate::{
    api::{
        error::{ApiError, ApiResult},
        resolve_user_id,
    },
    application::state::AppState,
    domain::{QualityMode, QualityProfile, RequestStatus, SessionState},
};

#[derive(Debug, Deserialize)]
pub struct CreateConnectionRequest {
    pub target_device_id: Uuid,
    pub initial_quality_profile: Option<QualityProfile>,
}

#[derive(Debug, Serialize)]
pub struct CreateConnectionResponse {
    pub request_id: Uuid,
    pub session_id: Uuid,
    pub status: RequestStatus,
    pub state: SessionState,
}

pub async fn create_connection_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateConnectionRequest>,
) -> ApiResult<Json<CreateConnectionResponse>> {
    let requester_user_id = resolve_user_id(&headers, &state).await?;

    let target_row = state
        .postgres
        .query_opt(
            "SELECT user_id, auto_approve_screen_share FROM devices WHERE id = $1",
            &[&payload.target_device_id],
        )
        .await
        .map_err(internal_connection_error)?;

    let Some(target_row) = target_row else {
        return Err(ApiError::not_found(
            "DEVICE_NOT_FOUND",
            "target device not found",
        ));
    };

    let target_owner: Uuid = target_row.get("user_id");
    let auto_approve: bool = target_row.get("auto_approve_screen_share");

    if target_owner != requester_user_id {
        return Err(ApiError::forbidden(
            "DEVICE_NOT_OWNED",
            "current mvp allows only same-account devices",
        ));
    }

    let target_online = state
        .is_device_online(payload.target_device_id)
        .await
        .map_err(internal_connection_error)?;
    if !target_online {
        return Err(ApiError::conflict(
            "DEVICE_OFFLINE",
            "target device is offline or desktop-server heartbeat is missing",
        ));
    }

    let request_id = Uuid::new_v4();
    let session_id = Uuid::new_v4();
    let now = Utc::now();

    let request_status = if auto_approve {
        RequestStatus::Accepted
    } else {
        RequestStatus::Requested
    };
    let session_state = if auto_approve {
        SessionState::Connecting
    } else {
        SessionState::PendingApproval
    };
    let quality_mode = if payload.initial_quality_profile.is_some() {
        QualityMode::Manual
    } else {
        QualityMode::Auto
    };
    let quality_profile = payload
        .initial_quality_profile
        .unwrap_or(QualityProfile::P720);

    state
        .postgres
        .execute(
            "INSERT INTO connection_requests (id, requester_user_id, target_device_id, status, created_at) VALUES ($1, $2, $3, $4, $5)",
            &[
                &request_id,
                &requester_user_id,
                &payload.target_device_id,
                &request_status.as_str(),
                &now,
            ],
        )
        .await
        .map_err(internal_connection_error)?;

    state
        .postgres
        .execute(
            "INSERT INTO share_sessions (id, request_id, requester_user_id, target_device_id, state, selected_screen_id, quality_mode, quality_profile, pause_deadline_at, created_at, updated_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            &[
                &session_id,
                &request_id,
                &requester_user_id,
                &payload.target_device_id,
                &session_state.as_str(),
                &Some("display-1".to_string()),
                &quality_mode.as_str(),
                &Some(quality_profile.as_str().to_string()),
                &Option::<chrono::DateTime<Utc>>::None,
                &now,
                &now,
            ],
        )
        .await
        .map_err(internal_connection_error)?;

    let requested_payload = serde_json::json!({
        "request_id": request_id,
        "target_device_id": payload.target_device_id,
        "request_status": request_status,
        "auto_approved": auto_approve,
        "session_state": session_state,
        "quality_mode": quality_mode,
        "quality_profile": quality_profile,
    });

    state
        .postgres
        .execute(
            "INSERT INTO session_events (session_id, event_type, created_at, payload) VALUES ($1, $2, $3, $4)",
            &[&session_id, &"session.requested", &now, &requested_payload],
        )
        .await
        .map_err(internal_connection_error)?;

    if auto_approve {
        let approved_payload = serde_json::json!({
            "request_id": request_id,
            "decision": "approve",
            "reason": "auto_approve_enabled",
            "state": session_state,
        });

        state
            .postgres
            .execute(
                "INSERT INTO session_events (session_id, event_type, created_at, payload) VALUES ($1, $2, $3, $4)",
                &[&session_id, &"session.approved", &now, &approved_payload],
            )
            .await
            .map_err(internal_connection_error)?;
    }

    let ws_event = serde_json::json!({
        "type": "session.requested",
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": now,
        "payload": {
            "request_id": request_id,
            "session_id": session_id,
            "requester_user_id": requester_user_id,
            "target_device_id": payload.target_device_id,
            "request_status": request_status,
            "auto_approved": auto_approve,
            "quality_profile": quality_profile,
        }
    });

    let desktop_subscribers = state
        .publish_desktop_event(payload.target_device_id, ws_event.to_string())
        .await;
    if !auto_approve && desktop_subscribers == 0 {
        warn!(
            session_id = %session_id,
            device_id = %payload.target_device_id,
            "connection request published without active desktop event subscribers"
        );

        reject_unroutable_request(
            &state,
            request_id,
            session_id,
            requester_user_id,
            payload.target_device_id,
            now,
            "desktop event stream unavailable",
        )
        .await
        .map_err(internal_connection_error)?;

        return Ok(Json(CreateConnectionResponse {
            request_id,
            session_id,
            status: RequestStatus::Rejected,
            state: SessionState::Terminated,
        }));
    }

    let mobile_event = serde_json::json!({
        "type": "connection.request.created",
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": now,
        "payload": {
            "request_id": request_id,
            "session_id": session_id,
            "target_device_id": payload.target_device_id,
            "status": request_status,
            "state": session_state,
        }
    });

    state
        .publish_mobile_event(requester_user_id, mobile_event.to_string())
        .await;

    if auto_approve {
        let accepted_event = serde_json::json!({
            "type": "connection.request.accepted",
            "event_id": Uuid::new_v4().to_string(),
            "timestamp": now,
            "payload": {
                "request_id": request_id,
                "session_id": session_id,
                "target_device_id": payload.target_device_id,
                "status": request_status,
                "state": session_state,
                "reason": "auto_approve_enabled",
            }
        });
        state
            .publish_mobile_event(requester_user_id, accepted_event.to_string())
            .await;
    }

    info!(
        request_id = %request_id,
        session_id = %session_id,
        device_id = %payload.target_device_id,
        desktop_subscribers,
        status = request_status.as_str(),
        state = session_state.as_str(),
        "connection request created"
    );

    Ok(Json(CreateConnectionResponse {
        request_id,
        session_id,
        status: request_status,
        state: session_state,
    }))
}

fn internal_connection_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal(
        "CONNECTION_INTERNAL",
        format!("connection internal error: {error}"),
    )
}

async fn reject_unroutable_request(
    state: &AppState,
    request_id: Uuid,
    session_id: Uuid,
    requester_user_id: Uuid,
    target_device_id: Uuid,
    now: chrono::DateTime<Utc>,
    reason: &str,
) -> anyhow::Result<()> {
    state
        .postgres
        .execute(
            "UPDATE connection_requests SET status = 'rejected' WHERE id = $1",
            &[&request_id],
        )
        .await?;

    state
        .postgres
        .execute(
            "UPDATE share_sessions SET state = 'terminated', updated_at = $2 WHERE id = $1",
            &[&session_id, &now],
        )
        .await?;

    let rejected_payload = serde_json::json!({
        "request_id": request_id,
        "decision": "reject",
        "reason": reason,
        "state": "terminated",
        "request_status": "rejected",
    });

    state
        .postgres
        .execute(
            "INSERT INTO session_events (session_id, event_type, created_at, payload) VALUES ($1, $2, $3, $4)",
            &[&session_id, &"session.rejected", &now, &rejected_payload],
        )
        .await?;

    let mobile_event = serde_json::json!({
        "type": "connection.request.rejected",
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": now,
        "payload": {
            "request_id": request_id,
            "session_id": session_id,
            "status": "rejected",
            "state": "terminated",
            "reason": reason,
            "target_device_id": target_device_id,
        }
    });
    state
        .publish_mobile_event(requester_user_id, mobile_event.to_string())
        .await;

    Ok(())
}
