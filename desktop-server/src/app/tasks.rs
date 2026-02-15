use std::time::Duration;

use chrono::Utc;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;
use tracing::{info, warn};
use uuid::Uuid;

use crate::app::state::AppState;

pub fn spawn_background_tasks(state: AppState) {
    spawn_backend_heartbeat(state.clone());
    spawn_backend_event_subscription(state.clone());
    spawn_snapshot_loop(state);
}

fn spawn_backend_heartbeat(state: AppState) {
    tokio::spawn(async move {
        let client = reqwest::Client::new();
        let interval = Duration::from_secs(state.config.backend.heartbeat_interval_seconds.max(1));
        let health_target = build_http_url(
            &state.config.backend.base_url,
            &state.config.backend.health_path,
        );
        let heartbeat_target = build_http_url(
            &state.config.backend.base_url,
            &state
                .config
                .backend
                .heartbeat_path
                .replace("{device_id}", &state.config.backend.device_id),
        );

        loop {
            let health_ok = match client.get(&health_target).send().await {
                Ok(response) if response.status().is_success() => {
                    info!(endpoint = %health_target, "backend health probe success");
                    true
                }
                Ok(response) => {
                    warn!(status = %response.status(), endpoint = %health_target, "backend health probe failed");
                    false
                }
                Err(error) => {
                    warn!(endpoint = %health_target, error = %error, "backend health probe error");
                    false
                }
            };

            let heartbeat_ok = match client
                .post(&heartbeat_target)
                .json(&serde_json::json!({ "source": "desktop-server" }))
                .send()
                .await
            {
                Ok(response) if response.status().is_success() => {
                    info!(endpoint = %heartbeat_target, "backend device heartbeat success");
                    true
                }
                Ok(response) => {
                    warn!(status = %response.status(), endpoint = %heartbeat_target, "backend device heartbeat failed");
                    false
                }
                Err(error) => {
                    warn!(endpoint = %heartbeat_target, error = %error, "backend device heartbeat error");
                    false
                }
            };

            if health_ok && heartbeat_ok {
                let mut runtime = state.runtime.write().await;
                runtime.backend_last_healthy_at = Some(Utc::now());
            }

            tokio::time::sleep(interval).await;
        }
    });
}

fn spawn_backend_event_subscription(state: AppState) {
    tokio::spawn(async move {
        let ws_url = build_ws_url(
            &state.config.backend.base_url,
            &state.config.backend.event_ws_path,
            &state.config.backend.device_id,
        );

        loop {
            info!(endpoint = %ws_url, "connecting backend event stream");
            match tokio_tungstenite::connect_async(&ws_url).await {
                Ok((mut socket, _)) => {
                    info!(endpoint = %ws_url, "backend event stream connected");

                    loop {
                        match socket.next().await {
                            Some(Ok(Message::Text(text))) => {
                                handle_backend_event(&state, &text).await;
                            }
                            Some(Ok(Message::Ping(payload))) => {
                                if socket.send(Message::Pong(payload)).await.is_err() {
                                    break;
                                }
                            }
                            Some(Ok(Message::Close(_))) => break,
                            Some(Ok(_)) => {}
                            Some(Err(error)) => {
                                warn!(endpoint = %ws_url, error = %error, "backend event stream error");
                                break;
                            }
                            None => break,
                        }
                    }

                    warn!(endpoint = %ws_url, "backend event stream disconnected");
                }
                Err(error) => {
                    warn!(endpoint = %ws_url, error = %error, "backend event stream connect failed");
                }
            }

            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
}

#[derive(Debug, Deserialize)]
struct BackendEvent {
    #[serde(rename = "type")]
    event_type: String,
    payload: serde_json::Value,
}

async fn handle_backend_event(state: &AppState, raw: &str) {
    let parsed: serde_json::Result<BackendEvent> = serde_json::from_str(raw);
    let Ok(event) = parsed else {
        warn!(payload = raw, "failed to parse backend event");
        return;
    };

    match event.event_type.as_str() {
        "session.requested" => {
            handle_session_requested(state, event.payload).await;
        }
        "session.control.pause"
        | "session.control.resume"
        | "session.control.terminate"
        | "session.control.switch_screen"
        | "session.control.quality_changed"
        | "webrtc.offer"
        | "webrtc.answer"
        | "webrtc.ice_candidate" => {
            let _ = state.local_events.send(raw.to_string());
            info!(event_type = %event.event_type, "forwarded backend event to desktop client");
        }
        _ => {
            info!(event_type = %event.event_type, payload = %event.payload, "received backend event");
        }
    }
}

async fn handle_session_requested(state: &AppState, payload: serde_json::Value) {
    let session_id = payload
        .get("session_id")
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);

    let Some(session_id) = session_id else {
        warn!(payload = %payload, "session.requested missing session_id");
        return;
    };

    let backend_auto_approved = payload
        .get("auto_approved")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let runtime = state.runtime.read().await;
    let local_auto_approved = runtime.auto_approve_screen_share;
    let desktop_connections = runtime.desktop_client_connections;
    drop(runtime);

    let should_auto_approve = backend_auto_approved || local_auto_approved;
    if should_auto_approve {
        info!(
            session_id = %session_id,
            backend_auto_approved,
            local_auto_approved,
            "auto approve enabled, approving session"
        );
        let _ = submit_session_decision(state, &session_id, true, None).await;
        return;
    }

    if desktop_connections == 0 {
        info!(session_id = %session_id, "desktop client offline, rejecting session");
        let _ = submit_session_decision(
            state,
            &session_id,
            false,
            Some("desktop client offline".to_string()),
        )
        .await;
        return;
    }

    let (sender, receiver) = oneshot::channel::<bool>();
    state
        .pending_authorizations
        .lock()
        .await
        .insert(session_id.clone(), sender);

    let authorize_message = serde_json::json!({
        "type": "authorize.request",
        "request_id": payload.get("request_id").cloned().unwrap_or(serde_json::Value::Null),
        "session_id": session_id,
        "requester": payload.get("requester_user_id").cloned().unwrap_or(serde_json::Value::Null),
        "target_device_id": payload.get("target_device_id").cloned().unwrap_or(serde_json::Value::Null),
    });
    let _ = state.local_events.send(authorize_message.to_string());

    let approved = match tokio::time::timeout(Duration::from_secs(30), receiver).await {
        Ok(Ok(value)) => value,
        Ok(Err(_)) => false,
        Err(_) => {
            let _ = state
                .pending_authorizations
                .lock()
                .await
                .remove(&session_id);
            false
        }
    };

    let reason = if approved {
        None
    } else {
        Some("authorization denied or timeout".to_string())
    };
    let _ = submit_session_decision(state, &session_id, approved, reason).await;
}

async fn submit_session_decision(
    state: &AppState,
    session_id: &str,
    approved: bool,
    reason: Option<String>,
) -> anyhow::Result<()> {
    let endpoint = build_http_url(
        &state.config.backend.base_url,
        &state
            .config
            .backend
            .session_decision_path
            .replace("{session_id}", session_id),
    );

    let device_id = Uuid::parse_str(&state.config.backend.device_id)
        .map_err(|error| anyhow::anyhow!("invalid backend.device_id: {error}"))?;

    let payload = serde_json::json!({
        "device_id": device_id,
        "decision": if approved { "approve" } else { "reject" },
        "reason": reason,
    });

    let response = reqwest::Client::new()
        .post(endpoint)
        .json(&payload)
        .send()
        .await?;
    if !response.status().is_success() {
        warn!(status = %response.status(), "submit session decision failed");
    }

    Ok(())
}

fn spawn_snapshot_loop(state: AppState) {
    tokio::spawn(async move {
        let interval = Duration::from_secs(state.config.capture.snapshot_interval_seconds.max(1));
        loop {
            info!(
                snapshot_width = state.config.capture.snapshot_width,
                "snapshot refresh tick"
            );
            tokio::time::sleep(interval).await;
        }
    });
}

fn build_ws_url(base_url: &str, path_template: &str, device_id: &str) -> String {
    let path = path_template.replace("{device_id}", device_id);
    let origin = base_url.trim_end_matches('/');

    if let Some(value) = origin.strip_prefix("https://") {
        return format!("wss://{value}{path}");
    }

    if let Some(value) = origin.strip_prefix("http://") {
        return format!("ws://{value}{path}");
    }

    format!("ws://{origin}{path}")
}

fn build_http_url(base_url: &str, path: &str) -> String {
    format!("{}{}", base_url.trim_end_matches('/'), path)
}
