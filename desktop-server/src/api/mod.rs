use axum::{routing::get, Router};

use crate::app::state::AppState;

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
        .route("/ws", get(ws::local_ws_upgrade))
        .with_state(state)
}
