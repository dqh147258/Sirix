use std::time::Duration;

use chrono::Utc;
use tracing::{info, warn};
use uuid::Uuid;

use crate::application::state::AppState;

pub fn spawn_background_tasks(state: AppState) {
    spawn_pause_timeout_terminator(state);
}

fn spawn_pause_timeout_terminator(state: AppState) {
    tokio::spawn(async move {
        let interval = Duration::from_secs(10);

        loop {
            if let Err(error) = terminate_expired_paused_sessions(&state).await {
                warn!(error = %error, "failed to terminate expired paused sessions");
            }

            tokio::time::sleep(interval).await;
        }
    });
}

async fn terminate_expired_paused_sessions(state: &AppState) -> anyhow::Result<()> {
    let now = Utc::now();

    let rows = state
        .postgres
        .query(
            "UPDATE share_sessions SET state = 'terminated', pause_deadline_at = NULL, updated_at = $1 WHERE state = 'paused' AND pause_deadline_at IS NOT NULL AND pause_deadline_at <= $1 RETURNING id, requester_user_id, target_device_id",
            &[&now],
        )
        .await?;

    if rows.is_empty() {
        return Ok(());
    }

    let terminated_count = rows.len();

    for row in rows {
        let session_id: Uuid = row.get("id");
        let requester_user_id: Uuid = row.get("requester_user_id");
        let target_device_id: Uuid = row.get("target_device_id");

        let event_payload = serde_json::json!({
            "state": "terminated",
            "reason": "pause_timeout",
            "pause_deadline_at": now,
        });

        state
            .postgres
            .execute(
                "INSERT INTO session_events (session_id, event_type, created_at, payload) VALUES ($1, $2, $3, $4)",
                &[&session_id, &"session.auto_terminated", &now, &event_payload],
            )
            .await?;

        let desktop_event = serde_json::json!({
            "type": "session.control.terminate",
            "event_id": Uuid::new_v4().to_string(),
            "timestamp": now,
            "payload": {
                "session_id": session_id,
                "state": "terminated",
                "reason": "pause_timeout",
            }
        });
        state
            .publish_desktop_event(target_device_id, desktop_event.to_string())
            .await;

        let mobile_event = serde_json::json!({
            "type": "session.auto_terminated",
            "event_id": Uuid::new_v4().to_string(),
            "timestamp": now,
            "payload": {
                "session_id": session_id,
                "state": "terminated",
                "reason": "pause_timeout",
                "target_device_id": target_device_id,
            }
        });
        state
            .publish_mobile_event(requester_user_id, mobile_event.to_string())
            .await;
    }

    info!(terminated_count, "auto terminated paused sessions");

    Ok(())
}
