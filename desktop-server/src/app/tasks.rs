use std::{fs, process::Command, time::Duration};

use base64::Engine as _;
use chrono::Utc;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::app::state::AppState;

const AUTH_MEDIA_TRACE_TAG: &str = "[MEDIA_AUTH_TRACE]";

pub fn spawn_background_tasks(state: AppState) {
    spawn_screen_capture_permission_probe(state.clone());
    spawn_runtime_settings_sync(state.clone());
    spawn_backend_heartbeat(state.clone());
    spawn_backend_event_subscription(state.clone());
    spawn_snapshot_loop(state);
}

fn spawn_screen_capture_permission_probe(state: AppState) {
    tokio::spawn(async move {
        #[cfg(target_os = "macos")]
        {
            let granted = tokio::task::spawn_blocking(request_macos_screen_capture_permission)
                .await
                .unwrap_or(false);

            if granted {
                debug!(
                    device_id = %state.config.backend.device_id,
                    "macos screen capture permission is granted"
                );
                state
                    .logger
                    .info("macos screen capture permission is granted");
            } else {
                warn!(
                    device_id = %state.config.backend.device_id,
                    "macos screen capture permission not granted yet"
                );
                state
                    .logger
                    .warn("macos screen capture permission not granted yet");
            }
        }

        #[cfg(not(target_os = "macos"))]
        {
            debug!("screen capture permission probe skipped on non-macos platform");
        }
    });
}

fn spawn_runtime_settings_sync(state: AppState) {
    tokio::spawn(async move {
        let client = reqwest::Client::new();
        let endpoint = build_http_url(
            &state.config.backend.base_url,
            &state.config.backend.runtime_settings_path,
        );

        loop {
            match client.get(&endpoint).send().await {
                Ok(response) if response.status().is_success() => {
                    match response.json::<serde_json::Value>().await {
                        Ok(payload) => {
                            let logging_enabled = payload
                                .get("logging_enabled")
                                .and_then(serde_json::Value::as_bool)
                                .unwrap_or(true);
                            let should_broadcast = {
                                let mut runtime = state.runtime.write().await;
                                let changed = runtime.logging_enabled != logging_enabled;
                                runtime.logging_enabled = logging_enabled;
                                changed
                            };
                            state.logger.set_enabled(logging_enabled);

                            if should_broadcast {
                                let runtime = state.runtime.read().await;
                                let _ = state.local_events.send(
                                serde_json::json!({
                                    "type": "settings.sync",
                                    "auto_approve_screen_share": runtime.auto_approve_screen_share,
                                    "device_id": state.config.backend.device_id,
                                    "local_ws_port": runtime.local_ws_port,
                                    "logging_enabled": runtime.logging_enabled,
                                })
                                .to_string(),
                            );
                            }
                        }
                        Err(error) => {
                            state.logger.warn(format!(
                                "failed to decode runtime settings response: {error}"
                            ));
                        }
                    }
                }
                Ok(response) => {
                    state.logger.warn(format!(
                        "runtime settings sync failed status={}",
                        response.status()
                    ));
                }
                Err(error) => {
                    state
                        .logger
                        .warn(format!("runtime settings sync error: {error}"));
                }
            }

            tokio::time::sleep(Duration::from_secs(10)).await;
        }
    });
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
                    debug!(endpoint = %health_target, "backend health probe success");
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
                    debug!(endpoint = %heartbeat_target, "backend device heartbeat success");
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
        let mut reconnect_delay = Duration::from_secs(1);

        loop {
            debug!(endpoint = %ws_url, "connecting backend event stream");
            match tokio_tungstenite::connect_async(&ws_url).await {
                Ok((mut socket, _)) => {
                    info!(endpoint = %ws_url, "backend event stream connected");
                    {
                        let mut runtime = state.runtime.write().await;
                        runtime.backend_event_stream_connected = true;
                    }
                    state
                        .logger
                        .info(format!("backend event stream connected endpoint={ws_url}"));
                    if let Err(error) = sync_pending_sessions(&state).await {
                        state.logger.warn(format!(
                            "pending session sync failed after connect: {error}"
                        ));
                    }
                    reconnect_delay = Duration::from_secs(1);

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
                    {
                        let mut runtime = state.runtime.write().await;
                        runtime.backend_event_stream_connected = false;
                    }
                    state.logger.warn(format!(
                        "backend event stream disconnected endpoint={ws_url}"
                    ));
                }
                Err(error) => {
                    warn!(endpoint = %ws_url, error = %error, "backend event stream connect failed");
                    state.logger.warn(format!(
                        "backend event stream connect failed endpoint={} error={error}",
                        ws_url
                    ));
                }
            }

            warn!(
                endpoint = %ws_url,
                reconnect_after_seconds = reconnect_delay.as_secs(),
                "backend event stream will retry"
            );
            state.logger.warn(format!(
                "backend event stream will retry endpoint={} reconnect_after_seconds={}",
                ws_url,
                reconnect_delay.as_secs()
            ));
            tokio::time::sleep(reconnect_delay).await;
            reconnect_delay = Duration::from_secs((reconnect_delay.as_secs().max(1) * 2).min(30));
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
        state
            .logger
            .warn(format!("failed to parse backend event payload={raw}"));
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
            debug!(event_type = %event.event_type, "forwarded backend event to desktop client");
        }
        _ => {
            debug!(event_type = %event.event_type, payload = %event.payload, "received backend event");
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
        state.logger.warn(format!(
            "session.requested missing session_id payload={payload}"
        ));
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
        if let Err(error) = submit_session_decision_with_retry(state, &session_id, true, None).await
        {
            warn!(session_id = %session_id, error = %error, "failed to approve session");
            state.logger.warn(format!(
                "failed to approve session session_id={} error={error}",
                session_id
            ));
        }
        return;
    }

    let approve_timeout = Duration::from_secs(
        state
            .config
            .authorization
            .manual_approve_timeout_seconds
            .max(1),
    );

    if desktop_connections == 0
        && !wait_for_desktop_client_connection(state, Duration::from_secs(5)).await
    {
        info!(session_id = %session_id, "desktop client offline, rejecting session");
        state.logger.warn(format!(
            "desktop client offline rejecting session session_id={session_id}"
        ));
        if let Err(error) = submit_session_decision_with_retry(
            state,
            &session_id,
            false,
            Some("desktop client offline".to_string()),
        )
        .await
        {
            warn!(session_id = %session_id, error = %error, "failed to reject session");
            state.logger.warn(format!(
                "failed to reject session session_id={} error={error}",
                session_id
            ));
        }
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
    if state
        .local_events
        .send(authorize_message.to_string())
        .is_err()
    {
        let _ = state
            .pending_authorizations
            .lock()
            .await
            .remove(&session_id);
        state.logger.warn(format!(
            "no local desktop listeners for authorize request session_id={session_id}"
        ));
        if let Err(error) = submit_session_decision_with_retry(
            state,
            &session_id,
            false,
            Some("desktop authorization UI not ready".to_string()),
        )
        .await
        {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to reject session without local desktop listeners"
            );
            state.logger.warn(format!(
                "failed to reject session without local desktop listeners session_id={} error={error}",
                session_id
            ));
        }
        return;
    }
    state.logger.info(format!(
        "forwarded authorize request to local desktop session_id={} desktop_connections={}",
        session_id, desktop_connections
    ));
    state.logger.info(format!(
        "{AUTH_MEDIA_TRACE_TAG} waiting authorization response session_id={} timeout_seconds={} desktop_connections={}",
        session_id,
        approve_timeout.as_secs(),
        desktop_connections
    ));

    let wait_started_at = tokio::time::Instant::now();
    let (approved, decision_source) = match tokio::time::timeout(approve_timeout, receiver).await {
        Ok(Ok(value)) => {
            state.logger.info(format!(
                "{AUTH_MEDIA_TRACE_TAG} authorization response received session_id={} approved={} elapsed_ms={}",
                session_id,
                value,
                wait_started_at.elapsed().as_millis()
            ));
            (value, "local_response")
        }
        Ok(Err(_)) => {
            state.logger.warn(format!(
                "{AUTH_MEDIA_TRACE_TAG} authorization channel dropped session_id={} elapsed_ms={}",
                session_id,
                wait_started_at.elapsed().as_millis()
            ));
            (false, "channel_dropped")
        }
        Err(_) => {
            let _ = state
                .pending_authorizations
                .lock()
                .await
                .remove(&session_id);
            state.logger.warn(format!(
                "{AUTH_MEDIA_TRACE_TAG} authorization wait timed out session_id={} timeout_seconds={} elapsed_ms={}",
                session_id,
                approve_timeout.as_secs(),
                wait_started_at.elapsed().as_millis()
            ));
            (false, "timeout")
        }
    };

    let reason = if approved {
        None
    } else {
        Some("authorization denied or timeout".to_string())
    };
    if let Err(error) =
        submit_session_decision_with_retry(state, &session_id, approved, reason).await
    {
        warn!(
            session_id = %session_id,
            approved,
            error = %error,
            "failed to submit authorization result"
        );
        state.logger.warn(format!(
            "failed to submit authorization result session_id={} approved={} error={error}",
            session_id, approved
        ));
    } else {
        state.logger.info(format!(
            "{AUTH_MEDIA_TRACE_TAG} authorization result submitted session_id={} approved={} source={} wait_ms={}",
            session_id,
            approved,
            decision_source,
            wait_started_at.elapsed().as_millis()
        ));
    }
}

async fn submit_session_decision_with_retry(
    state: &AppState,
    session_id: &str,
    approved: bool,
    reason: Option<String>,
) -> anyhow::Result<()> {
    let mut delay = Duration::from_secs(1);
    let max_attempts = 3;

    for attempt in 1..=max_attempts {
        match submit_session_decision(state, session_id, approved, reason.clone()).await {
            Ok(()) => return Ok(()),
            Err(error) if attempt < max_attempts => {
                warn!(
                    session_id = %session_id,
                    attempt,
                    retry_after_seconds = delay.as_secs(),
                    error = %error,
                    "submit session decision failed, retrying"
                );
                state.logger.warn(format!(
                    "submit session decision failed retrying session_id={} attempt={} retry_after_seconds={} error={error}",
                    session_id,
                    attempt,
                    delay.as_secs()
                ));
                tokio::time::sleep(delay).await;
                delay = Duration::from_secs((delay.as_secs().max(1) * 2).min(8));
            }
            Err(error) => return Err(error),
        }
    }

    unreachable!("retry loop must return on success or final error")
}

async fn sync_pending_sessions(state: &AppState) -> anyhow::Result<()> {
    let endpoint = build_http_url(
        &state.config.backend.base_url,
        &state
            .config
            .backend
            .pending_sessions_path
            .replace("{device_id}", &state.config.backend.device_id),
    );

    let pending = reqwest::Client::new()
        .get(&endpoint)
        .send()
        .await?
        .error_for_status()?
        .json::<Vec<serde_json::Value>>()
        .await?;

    for payload in &pending {
        handle_session_requested(state, payload.clone()).await;
    }

    if !pending.is_empty() {
        state
            .logger
            .info(format!("synced pending sessions count={}", pending.len()));
    }

    Ok(())
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
        let status = response.status();
        let body = response
            .text()
            .await
            .unwrap_or_else(|_| "<failed to read body>".to_string());
        anyhow::bail!("backend returned status {status} body={body}");
    }

    Ok(())
}

fn spawn_snapshot_loop(state: AppState) {
    tokio::spawn(async move {
        let interval_seconds = state.config.capture.snapshot_interval_seconds.max(1);
        let interval = Duration::from_secs(interval_seconds);

        loop {
            if let Err(error) = publish_screen_state_to_backend(&state).await {
                warn!(error = %error, "publish screen state failed");
            }

            tokio::time::sleep(interval).await;
        }
    });
}

#[derive(Debug, Serialize)]
struct ScreenStateUploadRequest {
    source: String,
    snapshot_ttl_seconds: u64,
    screens: Vec<ScreenInfoUpload>,
    snapshots: Vec<ScreenSnapshotUpload>,
}

#[derive(Debug, Serialize)]
struct ScreenInfoUpload {
    screen_id: String,
    name: String,
    width: u32,
    height: u32,
    is_primary: bool,
}

#[derive(Debug, Serialize)]
struct ScreenSnapshotUpload {
    screen_id: String,
    width: u32,
    height: u32,
    preview_base64: String,
    captured_at: chrono::DateTime<Utc>,
}

async fn publish_screen_state_to_backend(state: &AppState) -> anyhow::Result<()> {
    let endpoint = build_http_url(
        &state.config.backend.base_url,
        &state
            .config
            .backend
            .screen_state_path
            .replace("{device_id}", &state.config.backend.device_id),
    );

    let snapshot_width = state.config.capture.snapshot_width.max(160);
    let (screens, snapshots) =
        tokio::task::spawn_blocking(move || collect_local_screen_state(snapshot_width))
            .await
            .map_err(|error| anyhow::anyhow!("join blocking snapshot task failed: {error}"))??;

    let snapshot_ttl_seconds =
        (state.config.capture.snapshot_interval_seconds.max(1) * 3).clamp(15, 300);

    let payload = ScreenStateUploadRequest {
        source: "desktop-server".to_string(),
        snapshot_ttl_seconds,
        screens,
        snapshots,
    };

    let response = reqwest::Client::new()
        .post(&endpoint)
        .json(&payload)
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response
            .text()
            .await
            .unwrap_or_else(|_| "<failed to read body>".to_string());
        anyhow::bail!("backend returned status {status} body={body}");
    }

    debug!(endpoint = %endpoint, "published screen state to backend");

    Ok(())
}

async fn wait_for_desktop_client_connection(state: &AppState, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;

    loop {
        if state.runtime.read().await.desktop_client_connections > 0 {
            return true;
        }

        if tokio::time::Instant::now() >= deadline {
            return false;
        }

        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

fn collect_local_screen_state(
    snapshot_width: u32,
) -> anyhow::Result<(Vec<ScreenInfoUpload>, Vec<ScreenSnapshotUpload>)> {
    #[cfg(target_os = "macos")]
    {
        return collect_macos_screen_state(snapshot_width);
    }

    #[cfg(not(target_os = "macos"))]
    {
        let screens = vec![ScreenInfoUpload {
            screen_id: "display-1".to_string(),
            name: "Display 1".to_string(),
            width: 1920,
            height: 1080,
            is_primary: true,
        }];

        let snapshots = vec![ScreenSnapshotUpload {
            screen_id: "display-1".to_string(),
            width: snapshot_width,
            height: ((snapshot_width as f64) / (16.0 / 9.0)).round() as u32,
            preview_base64: String::new(),
            captured_at: Utc::now(),
        }];

        Ok((screens, snapshots))
    }
}

#[cfg(target_os = "macos")]
#[derive(Debug, Clone)]
struct MacDisplayMeta {
    display_index: u32,
    display_id: u32,
    width: u32,
    height: u32,
    is_primary: bool,
}

#[cfg(target_os = "macos")]
fn collect_macos_screen_state(
    snapshot_width: u32,
) -> anyhow::Result<(Vec<ScreenInfoUpload>, Vec<ScreenSnapshotUpload>)> {
    let displays = get_macos_displays()?;
    if displays.is_empty() {
        return Ok((Vec::new(), Vec::new()));
    }

    let captured_at = Utc::now();
    let mut screens = Vec::with_capacity(displays.len());
    let mut snapshots = Vec::with_capacity(displays.len());

    for display in displays {
        let screen_id = format!("display-{}", display.display_id);
        let screen_name = if display.is_primary {
            format!("Display {} (Primary)", display.display_index)
        } else {
            format!("Display {}", display.display_index)
        };

        screens.push(ScreenInfoUpload {
            screen_id: screen_id.clone(),
            name: screen_name,
            width: display.width.max(1),
            height: display.height.max(1),
            is_primary: display.is_primary,
        });

        let ratio = (display.width as f64 / display.height as f64).max(1.0);
        let preview_width = snapshot_width.max(160);
        let preview_height = ((preview_width as f64) / ratio).round().max(120.0) as u32;

        let preview_base64 =
            match capture_macos_display_preview(display.display_index, preview_width) {
                Ok(value) => value,
                Err(error) => {
                    let failed_display_index = display.display_index;
                    let failed_display_id = display.display_id;
                    warn!(
                        display_index = failed_display_index,
                        display_id = failed_display_id,
                        error = %error,
                        "capture display preview failed"
                    );
                    String::new()
                }
            };

        snapshots.push(ScreenSnapshotUpload {
            screen_id,
            width: preview_width,
            height: preview_height,
            preview_base64,
            captured_at,
        });
    }

    Ok((screens, snapshots))
}

#[cfg(target_os = "macos")]
fn capture_macos_display_preview(display_index: u32, target_width: u32) -> anyhow::Result<String> {
    let capture_path = std::env::temp_dir().join(format!(
        "freeloom-display-{}-{}.jpg",
        display_index,
        Uuid::new_v4()
    ));
    let resized_path = std::env::temp_dir().join(format!(
        "freeloom-display-{}-{}-resized.jpg",
        display_index,
        Uuid::new_v4()
    ));

    let capture_status = Command::new("screencapture")
        .arg("-x")
        .arg("-D")
        .arg(display_index.to_string())
        .arg("-t")
        .arg("jpg")
        .arg(&capture_path)
        .status()?;

    if !capture_status.success() {
        let _ = fs::remove_file(&capture_path);
        anyhow::bail!("screencapture failed with status {capture_status}");
    }

    let final_path = if target_width > 0 {
        match Command::new("sips")
            .arg("-Z")
            .arg(target_width.to_string())
            .arg(&capture_path)
            .arg("--out")
            .arg(&resized_path)
            .status()
        {
            Ok(status) if status.success() => resized_path.clone(),
            _ => capture_path.clone(),
        }
    } else {
        capture_path.clone()
    };

    let image_bytes = fs::read(&final_path)?;

    let _ = fs::remove_file(&capture_path);
    let _ = fs::remove_file(&resized_path);

    Ok(base64::engine::general_purpose::STANDARD.encode(image_bytes))
}

#[cfg(target_os = "macos")]
fn request_macos_screen_capture_permission() -> bool {
    unsafe {
        if CGPreflightScreenCaptureAccess() {
            return true;
        }

        CGRequestScreenCaptureAccess()
    }
}

#[cfg(target_os = "macos")]
fn get_macos_displays() -> anyhow::Result<Vec<MacDisplayMeta>> {
    let mut display_ids = [0u32; 16];
    let mut display_count: u32 = 0;

    let result = unsafe {
        CGGetOnlineDisplayList(
            display_ids.len() as u32,
            display_ids.as_mut_ptr(),
            &mut display_count as *mut u32,
        )
    };

    if result != 0 {
        anyhow::bail!("CGGetOnlineDisplayList failed with code {result}");
    }

    let main_display_id = unsafe { CGMainDisplayID() };

    let displays = display_ids
        .iter()
        .copied()
        .take(display_count as usize)
        .enumerate()
        .map(|(index, display_id)| {
            let width = unsafe { CGDisplayPixelsWide(display_id) as u32 };
            let height = unsafe { CGDisplayPixelsHigh(display_id) as u32 };

            MacDisplayMeta {
                display_index: (index + 1) as u32,
                display_id,
                width,
                height,
                is_primary: display_id == main_display_id,
            }
        })
        .collect::<Vec<_>>();

    Ok(displays)
}

#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGGetOnlineDisplayList(
        max_displays: u32,
        active_displays: *mut u32,
        display_count: *mut u32,
    ) -> i32;
    fn CGMainDisplayID() -> u32;
    fn CGDisplayPixelsWide(display: u32) -> usize;
    fn CGDisplayPixelsHigh(display: u32) -> usize;
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
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
