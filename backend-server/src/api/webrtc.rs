use axum::{extract::State, http::HeaderMap, Json};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    api::{
        error::{ApiError, ApiResult},
        resolve_user_id,
    },
    application::state::AppState,
    domain::SessionState,
};

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalRole {
    Mobile,
    Desktop,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalType {
    Offer,
    Answer,
    IceCandidate,
}

#[derive(Debug, Deserialize)]
pub struct WebrtcSignalRequest {
    pub session_id: Uuid,
    pub role: SignalRole,
    pub signal_type: SignalType,
    pub sdp: Option<String>,
    pub candidate: Option<serde_json::Value>,
    pub device_id: Option<Uuid>,
}

pub async fn relay_signal(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<WebrtcSignalRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let row = state
        .postgres
        .query_opt(
            "SELECT requester_user_id, target_device_id, state FROM share_sessions WHERE id = $1",
            &[&payload.session_id],
        )
        .await
        .map_err(internal_error)?;

    let Some(row) = row else {
        return Err(ApiError::not_found(
            "SESSION_NOT_FOUND",
            "session not found",
        ));
    };

    let requester_user_id: Uuid = row.get("requester_user_id");
    let target_device_id: Uuid = row.get("target_device_id");
    let session_state_raw: String = row.get("state");
    let session_state = SessionState::from_db(&session_state_raw);

    if session_state == SessionState::Terminated {
        return Err(ApiError::conflict(
            "SESSION_NOT_ACTIVE",
            "session already terminated",
        ));
    }

    match payload.role {
        SignalRole::Mobile => {
            let user_id = resolve_user_id(&headers, &state).await?;
            if user_id != requester_user_id {
                return Err(ApiError::forbidden(
                    "SESSION_NOT_ACTIVE",
                    "session does not belong to current user",
                ));
            }

            let message = serde_json::json!({
                "type": signal_type_to_event(&payload.signal_type),
                "event_id": Uuid::new_v4().to_string(),
                "timestamp": Utc::now(),
                "payload": {
                    "session_id": payload.session_id,
                    "from_role": "mobile",
                    "to_role": "desktop",
                    "sdp": payload.sdp,
                    "candidate": payload.candidate,
                }
            });

            state
                .publish_desktop_event(target_device_id, message.to_string())
                .await;
        }
        SignalRole::Desktop => {
            let Some(device_id) = payload.device_id else {
                return Err(ApiError::bad_request(
                    "SESSION_NOT_ACTIVE",
                    "desktop signal requires device_id",
                ));
            };

            if device_id != target_device_id {
                return Err(ApiError::forbidden(
                    "SESSION_NOT_ACTIVE",
                    "device mismatch for this session",
                ));
            }

            let message = serde_json::json!({
                "type": signal_type_to_event(&payload.signal_type),
                "event_id": Uuid::new_v4().to_string(),
                "timestamp": Utc::now(),
                "payload": {
                    "session_id": payload.session_id,
                    "from_role": "desktop",
                    "to_role": "mobile",
                    "sdp": payload.sdp,
                    "candidate": payload.candidate,
                }
            });

            state
                .publish_mobile_event(requester_user_id, message.to_string())
                .await;
        }
    }

    state
        .postgres
        .execute(
            "INSERT INTO session_events (session_id, event_type, created_at, payload) VALUES ($1, $2, $3, $4)",
            &[
                &payload.session_id,
                &"webrtc.signal.relayed",
                &Utc::now(),
                &serde_json::json!({
                    "role": payload.role,
                    "signal_type": payload.signal_type,
                }),
            ],
        )
        .await
        .map_err(internal_error)?;

    Ok(Json(serde_json::json!({
        "ok": true,
        "session_id": payload.session_id,
    })))
}

fn signal_type_to_event(signal_type: &SignalType) -> &'static str {
    match signal_type {
        SignalType::Offer => "webrtc.offer",
        SignalType::Answer => "webrtc.answer",
        SignalType::IceCandidate => "webrtc.ice_candidate",
    }
}

fn internal_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal("WEBRTC_INTERNAL", format!("webrtc internal error: {error}"))
}
