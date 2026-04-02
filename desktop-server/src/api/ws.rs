use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::Response,
};
use futures_util::StreamExt;
use serde::Deserialize;
use tracing::{info, warn};
use uuid::Uuid;

use crate::app::state::AppState;

const AUTH_MEDIA_TRACE_TAG: &str = "[MEDIA_AUTH_TRACE]";

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum LocalWsInbound {
    #[serde(
        rename = "settings.set_auto_approve",
        alias = "settings_set_auto_approve"
    )]
    SettingsSetAutoApprove { auto_approve_screen_share: bool },
    #[serde(rename = "authorize.response", alias = "authorize_response")]
    AuthorizeResponse {
        session_id: String,
        decision: String,
    },
    #[serde(rename = "webrtc.signal", alias = "webrtc_signal")]
    WebrtcSignal {
        session_id: String,
        signal_type: String,
        sdp: Option<String>,
        candidate: Option<serde_json::Value>,
    },
    #[serde(rename = "terminal.list", alias = "terminal_list")]
    TerminalList,
    #[serde(rename = "terminal.attach", alias = "terminal_attach")]
    TerminalAttach { terminal_id: String },
    #[serde(rename = "terminal.close", alias = "terminal_close")]
    TerminalClose { terminal_id: String },
    #[serde(rename = "terminal.input", alias = "terminal_input")]
    TerminalInput {
        terminal_id: String,
        data_base64: String,
    },
    #[serde(rename = "terminal.resize", alias = "terminal_resize")]
    TerminalResize {
        terminal_id: String,
        cols: u16,
        rows: u16,
    },
    #[serde(rename = "ping")]
    Ping,
}

pub async fn local_ws_upgrade(ws: WebSocketUpgrade, State(state): State<AppState>) -> Response {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, state: AppState) {
    {
        let mut runtime = state.runtime.write().await;
        runtime.desktop_client_connections += 1;
    }

    let mut local_receiver = state.local_events.subscribe();
    info!(
        device_id = %state.config.backend.device_id,
        "desktop flutter client connected to local websocket"
    );
    state.logger.info(format!(
        "desktop flutter client connected to local websocket device_id={}",
        state.config.backend.device_id
    ));

    let sync_message = {
        let runtime = state.runtime.read().await;
        build_settings_sync_message(
            &state,
            runtime.auto_approve_screen_share,
            runtime.local_ws_port,
            runtime.logging_enabled,
        )
    };
    if socket
        .send(Message::Text(sync_message.to_string()))
        .await
        .is_err()
    {
        let mut runtime = state.runtime.write().await;
        runtime.desktop_client_connections = runtime.desktop_client_connections.saturating_sub(1);
        state
            .logger
            .warn("failed to send initial settings sync to desktop flutter client".to_string());
        return;
    }

    loop {
        tokio::select! {
            incoming = socket.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<LocalWsInbound>(&text) {
                            Ok(LocalWsInbound::SettingsSetAutoApprove { auto_approve_screen_share }) => {
                                let reply = {
                                    let mut runtime = state.runtime.write().await;
                                    runtime.auto_approve_screen_share = auto_approve_screen_share;
                                    build_settings_sync_message(
                                        &state,
                                        runtime.auto_approve_screen_share,
                                        runtime.local_ws_port,
                                        runtime.logging_enabled,
                                    )
                                };
                                if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                    break;
                                }
                                state.logger.info(format!(
                                    "desktop auto approve updated auto_approve_screen_share={auto_approve_screen_share}"
                                ));
                            }
                            Ok(LocalWsInbound::AuthorizeResponse { session_id, decision }) => {
                                let approved = decision.eq_ignore_ascii_case("approve");
                                state.logger.info(format!(
                                    "{AUTH_MEDIA_TRACE_TAG} local authorize response received session_id={} approved={}",
                                    session_id, approved
                                ));
                                if let Some(sender) = state.pending_authorizations.lock().await.remove(&session_id) {
                                    let _ = sender.send(approved);
                                } else {
                                    state.logger.warn(format!(
                                        "{AUTH_MEDIA_TRACE_TAG} authorize response received without pending session session_id={} approved={}",
                                        session_id, approved
                                    ));
                                }
                                let reply = serde_json::json!({
                                    "type": "authorize.ack",
                                    "session_id": session_id,
                                    "accepted": approved,
                                });
                                if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                    break;
                                }
                                state.logger.info(format!(
                                    "received authorize response session_id={} approved={}",
                                    session_id, approved
                                ));
                            }
                            Ok(LocalWsInbound::WebrtcSignal { session_id, signal_type, sdp, candidate }) => {
                                match relay_webrtc_signal_to_backend(
                                    &state,
                                    session_id,
                                    signal_type,
                                    sdp,
                                    candidate,
                                ).await {
                                    Ok(()) => {
                                        let reply = serde_json::json!({
                                            "type": "webrtc.signal.ack",
                                            "status": "ok",
                                        });
                                        if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                            break;
                                        }
                                    }
                                    Err(error) => {
                                        warn!(error = %error, "relay webrtc signal failed");
                                        state.logger.warn(format!(
                                            "relay webrtc signal failed error={error}"
                                        ));
                                        let reply = serde_json::json!({
                                            "type": "webrtc.signal.ack",
                                            "status": "error",
                                            "message": error.to_string(),
                                        });
                                        if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                            break;
                                        }
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalList) => {
                                let reply = serde_json::json!({
                                    "type": "terminal.list",
                                    "payload": {
                                        "terminals": state.terminal_manager.list_snapshots().await,
                                    }
                                });
                                if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                    break;
                                }
                            }
                            Ok(LocalWsInbound::TerminalAttach { terminal_id }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if let Some(snapshot) = state.terminal_manager.get_snapshot(terminal_id).await {
                                            let reply = serde_json::json!({
                                                "type": "terminal.ready",
                                                "payload": snapshot,
                                            });
                                            if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                                break;
                                            }

                                            if let Some(data_base64) = state
                                                .terminal_manager
                                                .get_output_snapshot_base64(terminal_id)
                                                .await
                                            {
                                                let reply = serde_json::json!({
                                                    "type": "terminal.snapshot",
                                                    "payload": {
                                                        "terminal_id": terminal_id,
                                                        "data_base64": data_base64,
                                                    }
                                                });
                                                if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid terminal attach id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalClose { terminal_id }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if let Err(error) = state.terminal_manager.close(terminal_id).await {
                                            warn!(terminal_id = %terminal_id, error = %error, "local terminal close failed");
                                        }
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid terminal close id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalInput { terminal_id, data_base64 }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if let Err(error) = state.terminal_manager.write_input(terminal_id, &data_base64).await {
                                            warn!(terminal_id = %terminal_id, error = %error, "local terminal input failed");
                                        }
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid terminal input id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalResize { terminal_id, cols, rows }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if let Err(error) = state.terminal_manager.resize(terminal_id, cols, rows).await {
                                            warn!(terminal_id = %terminal_id, error = %error, "local terminal resize failed");
                                        }
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid terminal resize id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::Ping) => {
                                if socket
                                    .send(Message::Text(serde_json::json!({ "type": "pong" }).to_string()))
                                    .await
                                    .is_err()
                                {
                                    break;
                                }
                            }
                            Err(error) => {
                                warn!(error = %error, "invalid local ws message");
                                state
                                    .logger
                                    .warn(format!("invalid local ws message error={error}"));
                            }
                        }
                    }
                    Some(Ok(Message::Ping(data))) => {
                        if socket.send(Message::Pong(data)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Close(_))) => break,
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        warn!(error = %error, "local websocket closed with error");
                        state
                            .logger
                            .warn(format!("local websocket closed with error: {error}"));
                        break;
                    }
                    None => break,
                }
            }
            outbound = local_receiver.recv() => {
                match outbound {
                    Ok(payload) => {
                        if socket.send(Message::Text(payload)).await.is_err() {
                            break;
                        }
                    }
                    Err(error) => {
                        warn!(error = %error, "local event receiver error");
                        state
                            .logger
                            .warn(format!("local event receiver error: {error}"));
                        break;
                    }
                }
            }
        }
    }

    {
        let mut runtime = state.runtime.write().await;
        runtime.desktop_client_connections = runtime.desktop_client_connections.saturating_sub(1);
    }

    info!(
        device_id = %state.config.backend.device_id,
        "desktop flutter client disconnected"
    );
    state.logger.info(format!(
        "desktop flutter client disconnected device_id={}",
        state.config.backend.device_id
    ));
}

fn build_settings_sync_message(
    state: &AppState,
    auto_approve: bool,
    local_ws_port: u16,
    logging_enabled: bool,
) -> serde_json::Value {
    serde_json::json!({
        "type": "settings.sync",
        "auto_approve_screen_share": auto_approve,
        "device_id": state.config.backend.device_id,
        "local_ws_port": local_ws_port,
        "logging_enabled": logging_enabled,
    })
}

async fn relay_webrtc_signal_to_backend(
    state: &AppState,
    session_id: String,
    signal_type: String,
    sdp: Option<String>,
    candidate: Option<serde_json::Value>,
) -> anyhow::Result<()> {
    let endpoint = build_http_url(
        &state.config.backend.base_url,
        &state.config.backend.webrtc_signal_path,
    );
    let device_id = Uuid::parse_str(&state.config.backend.device_id)
        .map_err(|error| anyhow::anyhow!("invalid backend.device_id: {error}"))?;

    let payload = serde_json::json!({
        "session_id": session_id,
        "role": "desktop",
        "signal_type": signal_type,
        "sdp": sdp,
        "candidate": candidate,
        "device_id": device_id,
    });

    let response = reqwest::Client::new()
        .post(endpoint)
        .json(&payload)
        .send()
        .await?;

    if !response.status().is_success() {
        anyhow::bail!("backend returned status {}", response.status());
    }

    Ok(())
}

fn build_http_url(base_url: &str, path: &str) -> String {
    format!("{}{}", base_url.trim_end_matches('/'), path)
}
