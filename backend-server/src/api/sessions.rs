use axum::{
    extract::{Path, State},
    http::HeaderMap,
    Json,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    api::{
        error::{ApiError, ApiResult},
        resolve_user_id,
    },
    application::state::AppState,
    domain::{QualityMode, QualityProfile, SessionState},
};

#[derive(Debug, Serialize)]
pub struct SessionResponse {
    pub session_id: Uuid,
    pub state: SessionState,
    pub selected_screen_id: Option<String>,
    pub quality_mode: QualityMode,
    pub quality_profile: Option<QualityProfile>,
    pub pause_deadline_at: Option<chrono::DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
pub struct SwitchScreenRequest {
    pub screen_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QualityModeInput {
    Manual,
    Auto,
}

#[derive(Debug, Deserialize)]
pub struct UpdateQualityRequest {
    pub mode: QualityModeInput,
    pub profile: Option<QualityProfile>,
}

#[derive(Debug, Clone)]
struct SessionRecord {
    id: Uuid,
    requester_user_id: Uuid,
    target_device_id: Uuid,
    state: SessionState,
    selected_screen_id: Option<String>,
    quality_mode: QualityMode,
    quality_profile: Option<QualityProfile>,
    pause_deadline_at: Option<DateTime<Utc>>,
    updated_at: DateTime<Utc>,
}

pub async fn pause_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
) -> ApiResult<Json<SessionResponse>> {
    mutate_session(
        &state,
        &headers,
        session_id,
        "session.paused",
        "session.control.pause",
        |session| {
            session.state = SessionState::Paused;
            session.pause_deadline_at = Some(Utc::now() + Duration::minutes(3));
            session.updated_at = Utc::now();
            Ok(())
        },
    )
    .await
}

pub async fn resume_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
) -> ApiResult<Json<SessionResponse>> {
    mutate_session(
        &state,
        &headers,
        session_id,
        "session.resumed",
        "session.control.resume",
        |session| {
            if let Some(deadline) = session.pause_deadline_at {
                if deadline < Utc::now() {
                    session.state = SessionState::Terminated;
                    session.pause_deadline_at = None;
                    session.updated_at = Utc::now();
                    return Err(ApiError::bad_request(
                        "SESSION_NOT_ACTIVE",
                        "session pause timeout reached",
                    ));
                }
            }

            session.state = SessionState::Streaming;
            session.pause_deadline_at = None;
            session.updated_at = Utc::now();
            Ok(())
        },
    )
    .await
}

pub async fn terminate_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
) -> ApiResult<Json<SessionResponse>> {
    mutate_session(
        &state,
        &headers,
        session_id,
        "session.terminated",
        "session.control.terminate",
        |session| {
            session.state = SessionState::Terminated;
            session.pause_deadline_at = None;
            session.updated_at = Utc::now();
            Ok(())
        },
    )
    .await
}

pub async fn switch_screen(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
    Json(payload): Json<SwitchScreenRequest>,
) -> ApiResult<Json<SessionResponse>> {
    let screen_id = payload.screen_id;
    mutate_session(
        &state,
        &headers,
        session_id,
        "session.screen_switched",
        "session.control.switch_screen",
        move |session| {
            session.selected_screen_id = Some(screen_id.clone());
            session.updated_at = Utc::now();
            Ok(())
        },
    )
    .await
}

pub async fn update_quality(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
    Json(payload): Json<UpdateQualityRequest>,
) -> ApiResult<Json<SessionResponse>> {
    mutate_session(
        &state,
        &headers,
        session_id,
        "session.quality_updated",
        "session.control.quality_changed",
        |session| {
            match payload.mode {
                QualityModeInput::Manual => {
                    let Some(profile) = payload.profile.clone() else {
                        return Err(ApiError::bad_request(
                            "SESSION_NOT_ACTIVE",
                            "manual mode requires profile",
                        ));
                    };
                    session.quality_mode = QualityMode::Manual;
                    session.quality_profile = Some(profile);
                }
                QualityModeInput::Auto => {
                    session.quality_mode = QualityMode::Auto;
                    session.quality_profile = payload.profile.clone();
                }
            }
            session.updated_at = Utc::now();
            Ok(())
        },
    )
    .await
}

async fn mutate_session<F>(
    state: &AppState,
    headers: &HeaderMap,
    session_id: Uuid,
    event_type_db: &str,
    event_type_ws: &str,
    mutator: F,
) -> ApiResult<Json<SessionResponse>>
where
    F: FnOnce(&mut SessionRecord) -> ApiResult<()>,
{
    let user_id = resolve_user_id(headers, state).await?;

    let mut session = fetch_session(state, session_id).await?;

    if session.requester_user_id != user_id {
        return Err(ApiError::forbidden(
            "SESSION_NOT_ACTIVE",
            "session does not belong to current user",
        ));
    }

    mutator(&mut session)?;

    state
        .postgres
        .execute(
            "UPDATE share_sessions SET state = $2, selected_screen_id = $3, quality_mode = $4, quality_profile = $5, pause_deadline_at = $6, updated_at = $7 WHERE id = $1",
            &[
                &session.id,
                &session.state.as_str(),
                &session.selected_screen_id,
                &session.quality_mode.as_str(),
                &session.quality_profile.as_ref().map(|value| value.as_str().to_string()),
                &session.pause_deadline_at,
                &session.updated_at,
            ],
        )
        .await
        .map_err(internal_session_error)?;

    let event_payload = serde_json::json!({
        "state": session.state,
        "screen_id": session.selected_screen_id,
        "quality_mode": session.quality_mode,
        "quality_profile": session.quality_profile,
        "pause_deadline_at": session.pause_deadline_at,
    });

    state
        .postgres
        .execute(
            "INSERT INTO session_events (session_id, event_type, created_at, payload) VALUES ($1, $2, $3, $4)",
            &[&session.id, &event_type_db, &Utc::now(), &event_payload],
        )
        .await
        .map_err(internal_session_error)?;

    let ws_event = serde_json::json!({
        "type": event_type_ws,
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": Utc::now(),
        "payload": {
            "session_id": session.id,
            "requester_user_id": session.requester_user_id,
            "target_device_id": session.target_device_id,
            "state": session.state,
            "screen_id": session.selected_screen_id,
            "quality_mode": session.quality_mode,
            "quality_profile": session.quality_profile,
            "pause_deadline_at": session.pause_deadline_at,
        }
    });

    state
        .publish_desktop_event(session.target_device_id, ws_event.to_string())
        .await;

    let mobile_event = serde_json::json!({
        "type": "session.state.changed",
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": Utc::now(),
        "payload": {
            "session_id": session.id,
            "state": session.state,
            "screen_id": session.selected_screen_id,
            "quality_mode": session.quality_mode,
            "quality_profile": session.quality_profile,
            "pause_deadline_at": session.pause_deadline_at,
        }
    });

    state
        .publish_mobile_event(session.requester_user_id, mobile_event.to_string())
        .await;

    Ok(Json(SessionResponse {
        session_id: session.id,
        state: session.state,
        selected_screen_id: session.selected_screen_id,
        quality_mode: session.quality_mode,
        quality_profile: session.quality_profile,
        pause_deadline_at: session.pause_deadline_at,
    }))
}

async fn fetch_session(state: &AppState, session_id: Uuid) -> ApiResult<SessionRecord> {
    let row = state
        .postgres
        .query_opt(
            "SELECT id, requester_user_id, target_device_id, state, selected_screen_id, quality_mode, quality_profile, pause_deadline_at, updated_at FROM share_sessions WHERE id = $1",
            &[&session_id],
        )
        .await
        .map_err(internal_session_error)?;

    let Some(row) = row else {
        return Err(ApiError::not_found(
            "SESSION_NOT_FOUND",
            "session not found",
        ));
    };

    let state_value: String = row.get("state");
    let quality_mode_value: String = row.get("quality_mode");
    let quality_profile_value: Option<String> = row.get("quality_profile");

    Ok(SessionRecord {
        id: row.get("id"),
        requester_user_id: row.get("requester_user_id"),
        target_device_id: row.get("target_device_id"),
        state: SessionState::from_db(&state_value),
        selected_screen_id: row.get("selected_screen_id"),
        quality_mode: QualityMode::from_db(&quality_mode_value),
        quality_profile: quality_profile_value
            .as_ref()
            .map(|value| QualityProfile::from_db(value)),
        pause_deadline_at: row.get("pause_deadline_at"),
        updated_at: row.get("updated_at"),
    })
}

fn internal_session_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal(
        "SESSION_INTERNAL",
        format!("session internal error: {error}"),
    )
}
