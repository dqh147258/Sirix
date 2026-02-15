use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};

use crate::app::state::AppState;

#[derive(Debug, Serialize)]
pub struct SettingsResponse {
    pub auto_approve_screen_share: bool,
    pub local_ws_port: u16,
}

#[derive(Debug, Deserialize)]
pub struct SettingsPatch {
    pub auto_approve_screen_share: bool,
}

pub async fn get_settings(State(state): State<AppState>) -> Json<SettingsResponse> {
    let runtime = state.runtime.read().await;
    Json(SettingsResponse {
        auto_approve_screen_share: runtime.auto_approve_screen_share,
        local_ws_port: runtime.local_ws_port,
    })
}

pub async fn set_settings(
    State(state): State<AppState>,
    Json(payload): Json<SettingsPatch>,
) -> Json<SettingsResponse> {
    let mut runtime = state.runtime.write().await;
    runtime.auto_approve_screen_share = payload.auto_approve_screen_share;

    Json(SettingsResponse {
        auto_approve_screen_share: runtime.auto_approve_screen_share,
        local_ws_port: runtime.local_ws_port,
    })
}
