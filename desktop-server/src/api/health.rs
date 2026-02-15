use axum::{extract::State, Json};
use serde::Serialize;

use crate::app::state::{AppState, RuntimeState};

#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub runtime: RuntimeState,
}

pub async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    let runtime = state.runtime.read().await.clone();
    Json(HealthResponse {
        status: "ok",
        runtime,
    })
}
