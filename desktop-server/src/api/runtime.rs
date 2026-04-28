use axum::{extract::State, Json};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use tracing::warn;

use crate::app::state::AppState;

#[derive(Debug, Deserialize)]
pub struct RuntimeLogBatchRequest {
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub entries: Vec<RuntimeLogEntry>,
}

#[derive(Debug, Deserialize)]
pub struct RuntimeLogEntry {
    pub timestamp: Option<DateTime<Utc>>,
    pub level: Option<String>,
    pub message: String,
    pub context: Option<serde_json::Value>,
}

/// Ingest runtime logs from local child processes, currently the Sirix CLI
/// hosted inside desktop-server managed terminals.  Desktop-server forwards
/// these entries through the same backend runtime-log transport it uses for its
/// own logs, avoiding a second backend URL/config surface inside the CLI.
pub async fn ingest_runtime_logs(
    State(state): State<AppState>,
    Json(payload): Json<RuntimeLogBatchRequest>,
) -> Json<serde_json::Value> {
    let source = payload
        .source
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("sirix_cli");

    if source != "sirix_cli" {
        warn!(source, "rejected unsupported local runtime log source");
        return Json(serde_json::json!({
            "ok": false,
            "accepted": 0,
            "error": "unsupported_source",
        }));
    }

    let accepted = payload.entries.len();
    for entry in payload.entries {
        state.logger.ingest_external(
            source.to_string(),
            entry.level,
            entry.message,
            entry.context,
            entry.timestamp,
        );
    }

    Json(serde_json::json!({
        "ok": true,
        "accepted": accepted,
    }))
}
