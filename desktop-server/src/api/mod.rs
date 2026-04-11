use axum::{routing::get, Router};

use crate::app::state::AppState;

pub mod ai;
pub mod auth;
pub mod health;
pub mod settings;
pub mod ws;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health::health))
        .route(
            "/auth/session",
            get(auth::get_session)
                .post(auth::login)
                .delete(auth::logout),
        )
        .route("/auth/register", axum::routing::post(auth::register))
        .route(
            "/settings",
            get(settings::get_settings).patch(settings::set_settings),
        )
        .route(
            "/ai/config",
            get(ai::get_ai_config).patch(ai::set_ai_config),
        )
        .route("/ai/config/effective", get(ai::get_effective_ai_config))
        .route(
            "/ai/sessions",
            get(ai::list_sessions).post(ai::launch_session),
        )
        .route("/ai/sessions/resolve", get(ai::resolve_session))
        .route(
            "/ai/sessions/approvals/check",
            axum::routing::post(ai::check_approval),
        )
        .route(
            "/ai/sessions/approvals/resolve",
            axum::routing::post(ai::resolve_approval),
        )
        .route("/ws", get(ws::local_ws_upgrade))
        .with_state(state)
}
