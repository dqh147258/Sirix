use axum::{
    http::{header::AUTHORIZATION, HeaderMap},
    routing::{get, patch, post},
    Router,
};
use uuid::Uuid;

use crate::application::state::AppState;

pub mod auth;
pub mod ai_sessions;
pub mod connections;
pub mod desktop_control;
pub mod desktop_events;
pub mod devices;
pub mod error;
pub mod health;
pub mod mobile_events;
pub mod runtime;
pub mod session_events;
pub mod sessions;
pub mod terminals;
pub mod webrtc;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health::health))
        .route("/api/v1/runtime/settings", get(runtime::runtime_settings))
        .route("/api/v1/runtime/logs", post(runtime::ingest_runtime_logs))
        .route("/api/v1/auth/register", post(auth::register))
        .route("/api/v1/auth/login", post(auth::login))
        .route("/api/v1/auth/refresh", post(auth::refresh))
        .route("/api/v1/ai-sessions", get(ai_sessions::list_ai_sessions))
        .route(
            "/api/v1/ai-sessions/:ai_session_id/approvals",
            post(ai_sessions::create_ai_approval),
        )
        .route(
            "/api/v1/ai-sessions/:ai_session_id/approval-requests",
            post(ai_sessions::create_ai_approval_request),
        )
        .route(
            "/api/v1/ai-sessions/:ai_session_id/approvals/resolve",
            post(ai_sessions::resolve_ai_approval),
        )
        .route("/api/v1/devices/register", post(devices::register_device))
        .route("/api/v1/devices/my", get(devices::list_my_devices))
        .route(
            "/api/v1/devices/:device_id/settings",
            patch(devices::update_device_settings),
        )
        .route(
            "/api/v1/devices/:device_id/screens",
            get(devices::list_device_screens),
        )
        .route(
            "/api/v1/devices/:device_id/snapshots",
            get(devices::list_device_snapshots),
        )
        .route(
            "/api/v1/connections/requests",
            post(connections::create_connection_request),
        )
        .route(
            "/api/v1/sessions/:session_id/events",
            get(session_events::list_session_events),
        )
        .route(
            "/api/v1/sessions/:session_id/pause",
            post(sessions::pause_session),
        )
        .route(
            "/api/v1/sessions/:session_id/resume",
            post(sessions::resume_session),
        )
        .route(
            "/api/v1/sessions/:session_id/terminate",
            post(sessions::terminate_session),
        )
        .route(
            "/api/v1/sessions/:session_id/switch-screen",
            post(sessions::switch_screen),
        )
        .route(
            "/api/v1/sessions/:session_id/quality",
            post(sessions::update_quality),
        )
        .route(
            "/api/v1/terminals",
            post(terminals::create_terminal).get(terminals::list_terminals),
        )
        .route(
            "/api/v1/terminals/:terminal_id/close",
            post(terminals::close_terminal),
        )
        .route(
            "/api/v1/terminals/:terminal_id/ws",
            get(terminals::terminal_events_ws),
        )
        .route(
            "/api/v1/desktop/events/:device_id/ws",
            get(desktop_events::desktop_events_ws),
        )
        .route(
            "/api/v1/mobile/events/ws",
            get(mobile_events::mobile_events_ws),
        )
        .route(
            "/api/v1/desktop/sessions/:session_id/decision",
            post(desktop_control::decide_session),
        )
        .route(
            "/api/v1/desktop/devices/:device_id/heartbeat",
            post(desktop_control::heartbeat),
        )
        .route(
            "/api/v1/desktop/devices/:device_id/pending-sessions",
            get(desktop_control::list_pending_sessions),
        )
        .route(
            "/api/v1/desktop/devices/:device_id/screen-state",
            post(desktop_control::update_screen_state),
        )
        .route(
            "/api/v1/desktop/terminals/:terminal_id/state",
            post(terminals::update_terminal_state),
        )
        .route(
            "/api/v1/desktop/ai-sessions/local",
            post(ai_sessions::create_local_desktop_ai_session),
        )
        .route(
            "/api/v1/desktop/terminals/local",
            post(terminals::create_local_desktop_terminal),
        )
        .route(
            "/api/v1/desktop/terminals/:terminal_id/output",
            post(terminals::ingest_terminal_output),
        )
        .route("/api/v1/webrtc/signal", post(webrtc::relay_signal))
        .with_state(state)
}

pub async fn resolve_user_id(
    headers: &HeaderMap,
    state: &AppState,
) -> Result<Uuid, error::ApiError> {
    let token = bearer_token(headers)?;
    let user_id = state
        .resolve_access_user_id(token)
        .await
        .map_err(|_| error::ApiError::unauthorized("AUTH_TOKEN_EXPIRED", "token lookup failed"))?
        .ok_or(error::ApiError::unauthorized(
            "AUTH_TOKEN_EXPIRED",
            "token is invalid",
        ))?;

    Ok(user_id)
}

fn bearer_token(headers: &HeaderMap) -> Result<&str, error::ApiError> {
    let value = headers
        .get(AUTHORIZATION)
        .ok_or(error::ApiError::unauthorized(
            "AUTH_TOKEN_EXPIRED",
            "missing authorization",
        ))?
        .to_str()
        .map_err(|_| {
            error::ApiError::unauthorized("AUTH_TOKEN_EXPIRED", "invalid authorization")
        })?;

    let token = value
        .strip_prefix("Bearer ")
        .ok_or(error::ApiError::unauthorized(
            "AUTH_TOKEN_EXPIRED",
            "expected bearer token",
        ))?;

    Ok(token)
}
