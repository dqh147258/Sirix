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

    if matches!(
        session_state,
        SessionState::Requested | SessionState::PendingApproval
    ) {
        return Err(ApiError::conflict(
            "SESSION_NOT_ACTIVE",
            format!(
                "session in state '{}' cannot relay webrtc signals yet",
                session_state.as_str()
            ),
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

    if should_persist_signal_event(&payload.signal_type) {
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
    }

    if matches!(payload.role, SignalRole::Desktop)
        && matches!(payload.signal_type, SignalType::Answer)
        && session_state == SessionState::Connecting
    {
        promote_session_to_streaming(
            &state,
            payload.session_id,
            requester_user_id,
            target_device_id,
        )
        .await?;
    }

    Ok(Json(serde_json::json!({
        "ok": true,
        "session_id": payload.session_id,
    })))
}

async fn promote_session_to_streaming(
    state: &AppState,
    session_id: Uuid,
    requester_user_id: Uuid,
    target_device_id: Uuid,
) -> ApiResult<()> {
    let now = Utc::now();

    state
        .postgres
        .execute(
            "UPDATE share_sessions SET state = 'streaming', pause_deadline_at = NULL, updated_at = $2 WHERE id = $1",
            &[&session_id, &now],
        )
        .await
        .map_err(internal_error)?;

    let event_payload = serde_json::json!({
        "state": "streaming",
    });

    state
        .postgres
        .execute(
            "INSERT INTO session_events (session_id, event_type, created_at, payload) VALUES ($1, $2, $3, $4)",
            &[&session_id, &"session.streaming_started", &now, &event_payload],
        )
        .await
        .map_err(internal_error)?;

    let mobile_event = serde_json::json!({
        "type": "session.state.changed",
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": now,
        "payload": {
            "session_id": session_id,
            "state": "streaming",
        }
    });

    state
        .publish_mobile_event(requester_user_id, mobile_event.to_string())
        .await;

    let desktop_event = serde_json::json!({
        "type": "session.state.changed",
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": now,
        "payload": {
            "session_id": session_id,
            "state": "streaming",
            "target_device_id": target_device_id,
        }
    });

    state
        .publish_desktop_event(target_device_id, desktop_event.to_string())
        .await;

    Ok(())
}

fn signal_type_to_event(signal_type: &SignalType) -> &'static str {
    match signal_type {
        SignalType::Offer => "webrtc.offer",
        SignalType::Answer => "webrtc.answer",
        SignalType::IceCandidate => "webrtc.ice_candidate",
    }
}

fn should_persist_signal_event(signal_type: &SignalType) -> bool {
    match signal_type {
        // ICE candidate 数量高、生命周期短，而且同一 session 内经常成批出现。
        // 把每个 candidate 都落到 session_events 会让热路径多一次数据库写入，
        // 在自动授权和首连阶段尤其容易把真正关键的 offer/answer 转发链路拖慢。
        // 这里保留 offer/answer 的审计价值，主动跳过 candidate 的逐条持久化。
        SignalType::Offer | SignalType::Answer => true,
        SignalType::IceCandidate => false,
    }
}

fn internal_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal("WEBRTC_INTERNAL", format!("webrtc internal error: {error}"))
}
