use axum::{extract::State, Json};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use tracing::{debug, warn};

use crate::{
    api::error::{ApiError, ApiResult},
    application::{
        runtime_logging::{RuntimeLogSource, RuntimeSettings},
        state::AppState,
    },
};

#[derive(Debug, Serialize)]
pub struct RuntimeSettingsResponse {
    pub logging_enabled: bool,
    pub max_lines_per_file: usize,
    pub server_time: chrono::DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct RuntimeLogBatchRequest {
    pub source: RuntimeLogSource,
    #[serde(default)]
    pub entries: Vec<RuntimeLogEntry>,
}

#[derive(Debug, Deserialize)]
pub struct RuntimeLogEntry {
    pub timestamp: Option<chrono::DateTime<Utc>>,
    pub level: Option<String>,
    pub message: String,
    pub context: Option<serde_json::Value>,
}

pub async fn runtime_settings(
    State(state): State<AppState>,
) -> ApiResult<Json<RuntimeSettingsResponse>> {
    let RuntimeSettings {
        logging_enabled,
        max_lines_per_file,
    } = state.runtime_settings.as_ref().clone();

    Ok(Json(RuntimeSettingsResponse {
        logging_enabled,
        max_lines_per_file,
        server_time: Utc::now(),
    }))
}

pub async fn ingest_runtime_logs(
    State(state): State<AppState>,
    Json(payload): Json<RuntimeLogBatchRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    if !state.runtime_settings.logging_enabled {
        return Ok(Json(serde_json::json!({
            "ok": true,
            "accepted": 0,
            "logging_enabled": false,
        })));
    }

    let accepted = payload.entries.len();
    for entry in payload.entries {
        let timestamp = entry.timestamp.unwrap_or_else(Utc::now);
        let level = entry.level.unwrap_or_else(|| "INFO".to_string());
        let mut line = format!("{} {}", timestamp.to_rfc3339(), level.to_uppercase());
        line.push(' ');
        line.push_str(&entry.message);
        if let Some(context) = entry.context {
            line.push(' ');
            line.push_str(&context.to_string());
        }

        state
            .log_store
            .append_line(payload.source, line)
            .map_err(internal_error)?;
    }

    debug!(source = ?payload.source, accepted, "runtime logs ingested");

    Ok(Json(serde_json::json!({
        "ok": true,
        "accepted": accepted,
        "logging_enabled": state.runtime_settings.logging_enabled,
    })))
}

fn internal_error(error: impl std::fmt::Display) -> ApiError {
    warn!(error = %error, "runtime log ingestion failed");
    ApiError::internal(
        "RUNTIME_LOG_INTERNAL",
        format!("runtime log error: {error}"),
    )
}
