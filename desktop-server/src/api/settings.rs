use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};

use crate::app::state::AppState;

#[derive(Debug, Serialize)]
pub struct SettingsResponse {
    pub auto_approve_screen_share: bool,
    pub prefer_tmux_terminal: bool,
    pub local_ws_port: u16,
    pub device_id: String,
    pub logging_enabled: bool,
}

#[derive(Debug, Deserialize)]
pub struct SettingsPatch {
    pub auto_approve_screen_share: bool,
    pub prefer_tmux_terminal: Option<bool>,
}

pub async fn get_settings(State(state): State<AppState>) -> Json<SettingsResponse> {
    let runtime = state.runtime.read().await;
    Json(SettingsResponse {
        auto_approve_screen_share: runtime.auto_approve_screen_share,
        prefer_tmux_terminal: runtime.prefer_tmux_terminal,
        local_ws_port: runtime.local_ws_port,
        device_id: state.config.backend.device_id.clone(),
        logging_enabled: runtime.logging_enabled,
    })
}

pub async fn set_settings(
    State(state): State<AppState>,
    Json(payload): Json<SettingsPatch>,
) -> Json<SettingsResponse> {
    let (local_ws_port, logging_enabled, prefer_tmux_terminal) = {
        let mut runtime = state.runtime.write().await;
        runtime.auto_approve_screen_share = payload.auto_approve_screen_share;
        if let Some(prefer_tmux_terminal) = payload.prefer_tmux_terminal {
            runtime.prefer_tmux_terminal = prefer_tmux_terminal;
        }
        (
            runtime.local_ws_port,
            runtime.logging_enabled,
            runtime.prefer_tmux_terminal,
        )
    };

    let sync_event = serde_json::json!({
        "type": "settings.sync",
        "auto_approve_screen_share": payload.auto_approve_screen_share,
        "prefer_tmux_terminal": prefer_tmux_terminal,
        "device_id": state.config.backend.device_id,
        "local_ws_port": local_ws_port,
        "logging_enabled": logging_enabled,
    });
    let _ = state.local_events.send(sync_event.to_string());

    Json(SettingsResponse {
        auto_approve_screen_share: payload.auto_approve_screen_share,
        prefer_tmux_terminal,
        local_ws_port,
        device_id: state.config.backend.device_id.clone(),
        logging_enabled,
    })
}
