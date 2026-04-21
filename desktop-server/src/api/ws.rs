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

use crate::app::{state::AppState, terminal::manager::HostedTerminalCommand};

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
    #[serde(rename = "terminal.host.register", alias = "terminal_host_register")]
    TerminalHostRegister {
        terminal_id: String,
        host_token: String,
    },
    #[serde(rename = "terminal.host.output", alias = "terminal_host_output")]
    TerminalHostOutput {
        terminal_id: String,
        data_base64: String,
    },
    #[serde(rename = "terminal.host.resized", alias = "terminal_host_resized")]
    TerminalHostResized {
        terminal_id: String,
        cols: u16,
        rows: u16,
    },
    #[serde(rename = "terminal.host.closed", alias = "terminal_host_closed")]
    TerminalHostClosed { terminal_id: String },
    #[serde(rename = "terminal.host.error", alias = "terminal_host_error")]
    TerminalHostError {
        terminal_id: String,
        error_message: String,
    },
    #[serde(rename = "ping")]
    Ping {
        #[serde(default)]
        request_id: Option<String>,
    },
}

pub async fn local_ws_upgrade(ws: WebSocketUpgrade, State(state): State<AppState>) -> Response {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, state: AppState) {
    let mut counts_as_desktop_client = true;
    {
        let mut runtime = state.runtime.write().await;
        runtime.desktop_client_connections += 1;
    }

    let mut local_receiver = state.local_events.subscribe();
    let mut hosted_terminal_id: Option<Uuid> = None;
    let mut hosted_control_receiver: Option<
        tokio::sync::mpsc::UnboundedReceiver<HostedTerminalCommand>,
    > = None;
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
                            Ok(LocalWsInbound::TerminalHostRegister { terminal_id, host_token }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        let (sender, receiver) = tokio::sync::mpsc::unbounded_channel();
                                        match state
                                            .terminal_manager
                                            .register_hosted_terminal(terminal_id, &host_token, sender)
                                            .await
                                        {
                                            Ok(()) => {
                                                if counts_as_desktop_client {
                                                    let mut runtime = state.runtime.write().await;
                                                    runtime.desktop_client_connections = runtime.desktop_client_connections.saturating_sub(1);
                                                    counts_as_desktop_client = false;
                                                }
                                                hosted_terminal_id = Some(terminal_id);
                                                hosted_control_receiver = Some(receiver);
                                                let reply = serde_json::json!({
                                                    "type": "terminal.host.registered",
                                                    "payload": {
                                                        "terminal_id": terminal_id,
                                                        "ok": true,
                                                    }
                                                });
                                                if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                                    break;
                                                }
                                            }
                                            Err(error) => {
                                                warn!(terminal_id = %terminal_id, error = %error, "hosted terminal register failed");
                                                let reply = serde_json::json!({
                                                    "type": "terminal.host.registered",
                                                    "payload": {
                                                        "terminal_id": terminal_id,
                                                        "ok": false,
                                                        "error_message": error.to_string(),
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
                                            "invalid hosted terminal register id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalHostOutput { terminal_id, data_base64 }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if let Err(error) = state
                                            .terminal_manager
                                            .ingest_hosted_output(terminal_id, &data_base64)
                                            .await
                                        {
                                            warn!(terminal_id = %terminal_id, error = %error, "hosted terminal output ingest failed");
                                            break;
                                        }
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid hosted terminal output id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalHostResized { terminal_id, cols, rows }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if let Err(error) = state
                                            .terminal_manager
                                            .update_hosted_terminal_size(terminal_id, cols, rows)
                                            .await
                                        {
                                            warn!(terminal_id = %terminal_id, error = %error, "hosted terminal resize update failed");
                                            break;
                                        }
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid hosted terminal resized id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalHostClosed { terminal_id }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if let Err(error) = state
                                            .terminal_manager
                                            .complete_hosted_terminal(terminal_id, None)
                                            .await
                                        {
                                            warn!(terminal_id = %terminal_id, error = %error, "hosted terminal close failed");
                                        }
                                        hosted_terminal_id = None;
                                        break;
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid hosted terminal close id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalHostError { terminal_id, error_message }) => {
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if let Err(error) = state
                                            .terminal_manager
                                            .complete_hosted_terminal(terminal_id, Some(error_message))
                                            .await
                                        {
                                            warn!(terminal_id = %terminal_id, error = %error, "hosted terminal error close failed");
                                        }
                                        hosted_terminal_id = None;
                                        break;
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid hosted terminal error id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::Ping { request_id }) => {
                                let reply = if let Some(request_id) = request_id.filter(|value| !value.trim().is_empty()) {
                                    serde_json::json!({
                                        "type": "pong",
                                        "request_id": request_id,
                                    })
                                } else {
                                    serde_json::json!({ "type": "pong" })
                                };
                                if socket
                                    .send(Message::Text(reply.to_string()))
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
            hosted_command = async {
                match hosted_control_receiver.as_mut() {
                    Some(receiver) => receiver.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                match hosted_command {
                    Some(command) => {
                        match serde_json::to_string(&command) {
                            Ok(payload) => {
                                if socket.send(Message::Text(payload)).await.is_err() {
                                    break;
                                }
                            }
                            Err(error) => {
                                warn!(error = %error, "failed to serialize hosted terminal command");
                                break;
                            }
                        }
                    }
                    None => {
                        hosted_control_receiver = None;
                    }
                }
            }
            outbound = local_receiver.recv() => {
                if hosted_terminal_id.is_some() {
                    continue;
                }
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

    if let Some(terminal_id) = hosted_terminal_id {
        if let Err(error) = state
            .terminal_manager
            .hosted_terminal_disconnected(terminal_id)
            .await
        {
            warn!(terminal_id = %terminal_id, error = %error, "hosted terminal disconnect cleanup failed");
        }
    }

    if counts_as_desktop_client {
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
