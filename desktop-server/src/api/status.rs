use axum::{extract::State, Json};

use crate::app::{state::AppState, status::build_status_overview};

pub async fn get_status_overview(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(
        serde_json::to_value(build_status_overview(&state).await)
            .expect("status overview should serialize"),
    )
}
