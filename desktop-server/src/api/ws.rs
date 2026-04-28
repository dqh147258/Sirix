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

use crate::app::{
    state::AppState,
    terminal::{
        geometry_arbiter::TerminalClientKind,
        protocol::{
            attach_payload_terminal_id, bootstrap_terminal_id, build_raw_terminal_ready_message,
            build_raw_terminal_snapshot_message, build_terminal_list_message, detach_request_parts,
            history_request_parts, is_authority_protocol, is_raw_stream_protocol,
            resize_request_parts, TerminalAttachPayload, TerminalBootstrapRequestPayload,
            TerminalDetachPayload, TerminalHistoryRangeRequestPayload, TerminalResizePayload,
        },
    },
};

const AUTH_MEDIA_TRACE_TAG: &str = "[MEDIA_AUTH_TRACE]";
const TERMINAL_VIEWER_DETACH_DEBOUNCE_MS: u64 = 750;

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
    TerminalAttach {
        terminal_id: Option<String>,
        payload: Option<TerminalAttachPayload>,
    },
    #[serde(
        rename = "terminal.bootstrap.request",
        alias = "terminal_bootstrap_request"
    )]
    TerminalBootstrapRequest {
        terminal_id: Option<String>,
        payload: Option<TerminalBootstrapRequestPayload>,
    },
    #[serde(
        rename = "terminal.history.range.request",
        alias = "terminal_history_range_request"
    )]
    TerminalHistoryRangeRequest {
        request_id: Option<String>,
        terminal_id: Option<String>,
        history_generation: Option<u64>,
        start_line: Option<i64>,
        end_line: Option<i64>,
        payload: Option<TerminalHistoryRangeRequestPayload>,
    },
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
        client_kind: Option<String>,
        viewer_presence_epoch: Option<u64>,
        payload: Option<TerminalResizePayload>,
    },
    #[serde(rename = "terminal.detach", alias = "terminal_detach")]
    TerminalDetach {
        terminal_id: String,
        client_kind: Option<String>,
        viewer_presence_epoch: Option<u64>,
        payload: Option<TerminalDetachPayload>,
    },
    #[serde(rename = "ping")]
    Ping {
        #[serde(default)]
        request_id: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
struct LocalWsOutboundEnvelope {
    #[serde(rename = "type")]
    event_type: String,
    payload: Option<LocalWsOutboundPayload>,
}

#[derive(Debug, Deserialize)]
struct LocalWsOutboundPayload {
    terminal_id: Option<String>,
    ai_session_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RawTerminalForwardTarget {
    Terminal(Uuid),
    AiSession(Uuid),
    Global,
}

fn raw_terminal_forward_target(raw: &str) -> Option<RawTerminalForwardTarget> {
    let Ok(envelope) = serde_json::from_str::<LocalWsOutboundEnvelope>(raw) else {
        return None;
    };

    if let Some(payload) = envelope.payload {
        if let Some(terminal_id) = payload
            .terminal_id
            .as_deref()
            .and_then(|value| Uuid::parse_str(value).ok())
        {
            return Some(RawTerminalForwardTarget::Terminal(terminal_id));
        }

        if matches!(
            envelope.event_type.as_str(),
            "ai.approval.request" | "ai.approval.resolved"
        ) {
            // Some approval events are emitted by spawned-agent / backend-sync
            // paths that know the AI session but do not carry the terminal id.
            // Raw system-terminal sockets are attached by terminal id, so keep
            // these events targetable through the session registry instead of
            // dropping them before the CLI approval overlay can render.
            return payload
                .ai_session_id
                .as_deref()
                .and_then(|value| Uuid::parse_str(value).ok())
                .map(RawTerminalForwardTarget::AiSession);
        }

        return None;
    }

    matches!(
        envelope.event_type.as_str(),
        "terminal.error" | "terminal.closed"
    )
    .then_some(RawTerminalForwardTarget::Global)
}

async fn should_forward_to_raw_terminal_socket(
    state: &AppState,
    raw: &str,
    attached_terminal_id: Uuid,
) -> bool {
    should_forward_to_raw_terminal_socket_with_registry(
        state.ai_session_registry.as_ref(),
        raw,
        attached_terminal_id,
    )
    .await
}

async fn should_forward_to_raw_terminal_socket_with_registry(
    ai_session_registry: &crate::app::ai::session::AiSessionRegistry,
    raw: &str,
    attached_terminal_id: Uuid,
) -> bool {
    match raw_terminal_forward_target(raw) {
        Some(RawTerminalForwardTarget::Terminal(event_terminal_id)) => {
            event_terminal_id == attached_terminal_id
        }
        Some(RawTerminalForwardTarget::AiSession(ai_session_id)) => ai_session_registry
            .resolve(ai_session_id)
            .await
            .is_some_and(|record| record.terminal_id == attached_terminal_id),
        Some(RawTerminalForwardTarget::Global) => true,
        None => false,
    }
}

pub async fn local_ws_upgrade(ws: WebSocketUpgrade, State(state): State<AppState>) -> Response {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, state: AppState) {
    let socket_id = Uuid::new_v4();
    let mut counts_as_desktop_client = true;
    let mut attached_viewers: std::collections::HashMap<Uuid, (TerminalClientKind, u64)> =
        std::collections::HashMap::new();
    {
        let mut runtime = state.runtime.write().await;
        runtime.desktop_client_connections += 1;
    }

    let mut local_receiver = state.local_events.subscribe();
    let mut raw_attached_terminal_id: Option<Uuid> = None;
    info!(
        socket_id = %socket_id,
        device_id = %state.config.backend.device_id,
        "desktop flutter client connected to local websocket"
    );
    state.logger.info(format!(
        "desktop flutter client connected to local websocket socket_id={} device_id={}",
        socket_id, state.config.backend.device_id
    ));

    let sync_message = {
        let runtime = state.runtime.read().await;
        build_settings_sync_message(
            &state,
            runtime.auto_approve_screen_share,
            runtime.prefer_tmux_terminal,
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
                                        runtime.prefer_tmux_terminal,
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
                                let reply = build_terminal_list_message(
                                    state.terminal_manager.list_snapshots().await,
                                );
                                if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                    break;
                                }
                            }
                            Ok(LocalWsInbound::TerminalAttach { terminal_id, payload }) => {
                                let (terminal_id, protocol_version, sync_mode, client_kind) =
                                    attach_payload_terminal_id(terminal_id, payload);
                                let Some(terminal_id) = terminal_id else {
                                    state.logger.warn(
                                        "terminal attach missing terminal_id".to_string()
                                    );
                                    continue;
                                };
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        if client_kind != TerminalClientKind::Unknown {
                                            if client_kind == TerminalClientKind::SystemTerminal
                                                && counts_as_desktop_client
                                            {
                                                let mut runtime = state.runtime.write().await;
                                                runtime.desktop_client_connections = runtime.desktop_client_connections.saturating_sub(1);
                                                counts_as_desktop_client = false;
                                            }
                                            let epoch = state
                                                .terminal_manager
                                                .register_viewer(terminal_id, client_kind)
                                                .await
                                                .unwrap_or_default();
                                            let previous = attached_viewers.insert(terminal_id, (client_kind, epoch));
                                            if let Some((previous_kind, _)) = previous {
                                                if previous_kind != client_kind {
                                                    let _ = state.terminal_manager.unregister_viewer(terminal_id, previous_kind).await;
                                                }
                                            }
                                        }
                                        if is_authority_protocol(protocol_version, sync_mode.as_deref()) {
                                            if client_kind == TerminalClientKind::SystemTerminal {
                                                raw_attached_terminal_id = None;
                                            }
                                            continue;
                                        }
                                        if !is_raw_stream_protocol(
                                            protocol_version,
                                            sync_mode.as_deref(),
                                        ) {
                                            let reply = serde_json::json!({
                                                "type": "terminal.error",
                                                "payload": {
                                                    "terminal_id": terminal_id,
                                                    "error_message": format!(
                                                        "unsupported terminal protocol version={} sync_mode={}",
                                                        protocol_version,
                                                        sync_mode.as_deref().unwrap_or("unknown"),
                                                    ),
                                                }
                                            });
                                            if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                                break;
                                            }
                                            continue;
                                        }
                                        if client_kind != TerminalClientKind::SystemTerminal {
                                            let reply = serde_json::json!({
                                                "type": "terminal.error",
                                                "payload": {
                                                    "terminal_id": terminal_id,
                                                    "error_message": "raw-v1 terminal protocol is restricted to system_terminal CLI fallback clients",
                                                }
                                            });
                                            if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                                break;
                                            }
                                            continue;
                                        }
                                        if client_kind == TerminalClientKind::SystemTerminal
                                            && is_raw_stream_protocol(protocol_version, sync_mode.as_deref())
                                        {
                                            raw_attached_terminal_id = Some(terminal_id);
                                        }
                                        if let Some(snapshot) = state.terminal_manager.get_snapshot(terminal_id).await {
                                            let viewer_presence_epoch = attached_viewers
                                                .get(&terminal_id)
                                                .map(|(_, epoch)| *epoch)
                                                .filter(|epoch| *epoch > 0);
                                            let reply = build_raw_terminal_ready_message(
                                                &snapshot,
                                                viewer_presence_epoch,
                                            );
                                            if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                                break;
                                            }

                                            if let Some(snapshot) = state
                                                .terminal_manager
                                                .get_output_snapshot(terminal_id)
                                                .await
                                            {
                                                if snapshot.history_truncated {
                                                    state.logger.info(format!(
                                                        "[TERMINAL_STREAM_TRACE] skipped truncated terminal snapshot terminal_id={} latest_output_sequence={}",
                                                        terminal_id,
                                                        snapshot.latest_sequence,
                                                    ));
                                                } else {
                                                    let reply = build_raw_terminal_snapshot_message(
                                                        terminal_id,
                                                        &snapshot,
                                                    );
                                                    if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                                        break;
                                                    }
                                                }
                                            }
                                        } else {
                                            let reply = serde_json::json!({
                                                "type": "terminal.error",
                                                "payload": {
                                                    "terminal_id": terminal_id,
                                                    "error_message": "terminal session not found",
                                                }
                                            });
                                            if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                                break;
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
                            Ok(LocalWsInbound::TerminalBootstrapRequest { terminal_id, payload }) => {
                                let Some(terminal_id) = bootstrap_terminal_id(terminal_id, payload) else {
                                    state.logger.warn(
                                        "terminal bootstrap request missing terminal_id".to_string()
                                    );
                                    continue;
                                };
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        let viewer_presence_epoch = attached_viewers
                                            .get(&terminal_id)
                                            .map(|(_, epoch)| *epoch)
                                            .filter(|epoch| *epoch > 0);
                                        match state
                                            .terminal_manager
                                            .bootstrap_v2(terminal_id, viewer_presence_epoch)
                                            .await
                                        {
                                            Ok(messages) => {
                                                for message in messages {
                                                    if socket.send(Message::Text(message.to_string())).await.is_err() {
                                                        break;
                                                    }
                                                }
                                            }
                                            Err(error) => {
                                                warn!(terminal_id = %terminal_id, error = %error, "local terminal bootstrap failed");
                                            }
                                        }
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid terminal bootstrap id terminal_id={} error={error}",
                                            terminal_id
                                        ));
                                    }
                                }
                            }
                            Ok(LocalWsInbound::TerminalHistoryRangeRequest {
                                request_id,
                                terminal_id,
                                history_generation,
                                start_line,
                                end_line,
                                payload,
                            }) => {
                                let Some((request_id, terminal_id, history_generation, start_line, end_line)) =
                                    history_request_parts(
                                        request_id,
                                        terminal_id,
                                        history_generation,
                                        start_line,
                                        end_line,
                                        payload,
                                    )
                                else {
                                    state.logger.warn(
                                        "terminal history range request missing fields".to_string()
                                    );
                                    continue;
                                };
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        match state
                                            .terminal_manager
                                            .history_range_response(
                                                terminal_id,
                                                request_id,
                                                history_generation,
                                                start_line,
                                                end_line,
                                            )
                                            .await
                                        {
                                            Ok(message) => {
                                                if socket.send(Message::Text(message.to_string())).await.is_err() {
                                                    break;
                                                }
                                            }
                                            Err(error) => {
                                                warn!(terminal_id = %terminal_id, error = %error, "local history range request failed");
                                            }
                                        }
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid terminal history range id terminal_id={} error={error}",
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
                            Ok(LocalWsInbound::TerminalResize {
                                terminal_id,
                                cols,
                                rows,
                                client_kind,
                                viewer_presence_epoch,
                                payload,
                            }) => {
                                let (terminal_id, cols, rows, client_kind, viewer_presence_epoch) =
                                    resize_request_parts(
                                        terminal_id,
                                        cols,
                                        rows,
                                        client_kind,
                                        viewer_presence_epoch,
                                        payload,
                                    );
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        let client_kind = TerminalClientKind::from_wire(client_kind.as_deref());
                                        if let Err(error) = state
                                            .terminal_manager
                                            .resize_from_client_if_epoch(
                                                terminal_id,
                                                cols,
                                                rows,
                                                client_kind,
                                                viewer_presence_epoch,
                                            )
                                            .await
                                        {
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
                            Ok(LocalWsInbound::TerminalDetach {
                                terminal_id,
                                client_kind,
                                viewer_presence_epoch,
                                payload,
                            }) => {
                                let (terminal_id, client_kind, viewer_presence_epoch) =
                                    detach_request_parts(
                                        terminal_id,
                                        client_kind,
                                        viewer_presence_epoch,
                                        payload,
                                    );
                                match Uuid::parse_str(&terminal_id) {
                                    Ok(terminal_id) => {
                                        let client_kind =
                                            TerminalClientKind::from_wire(client_kind.as_deref());
                                        if let Err(error) = state
                                            .terminal_manager
                                            .unregister_viewer_if_epoch(
                                                terminal_id,
                                                client_kind,
                                                viewer_presence_epoch,
                                            )
                                            .await
                                        {
                                            warn!(terminal_id = %terminal_id, error = %error, "local terminal detach failed");
                                        }
                                        attached_viewers.remove(&terminal_id);
                                    }
                                    Err(error) => {
                                        state.logger.warn(format!(
                                            "invalid terminal detach id terminal_id={} error={error}",
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
            outbound = local_receiver.recv() => {
                match outbound {
                    Ok(payload) => {
                        if let Some(attached_terminal_id) = raw_attached_terminal_id {
                            if !should_forward_to_raw_terminal_socket(
                                &state,
                                &payload,
                                attached_terminal_id,
                            )
                            .await
                            {
                                continue;
                            }
                        }
                        if socket.send(Message::Text(payload)).await.is_err() {
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(
                            skipped = skipped,
                            "local event receiver lagged"
                        );
                        state.logger.warn(format!(
                            "local event receiver lagged skipped={}",
                            skipped
                        ));
                        if let Some(attached_terminal_id) = raw_attached_terminal_id {
                            if let Some(snapshot) = state
                                .terminal_manager
                                .get_output_snapshot(attached_terminal_id)
                                .await
                            {
                                if !snapshot.history_truncated {
                                    let reply = build_raw_terminal_snapshot_message(
                                        attached_terminal_id,
                                        &snapshot,
                                    );
                                    if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                        break;
                                    }
                                }
                            }
                        }
                        continue;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        warn!("local event receiver closed");
                        state
                            .logger
                            .warn("local event receiver closed".to_string());
                        break;
                    }
                }
            }
        }
    }

    for (terminal_id, (client_kind, epoch)) in attached_viewers {
        let state = state.clone();
        tokio::spawn(async move {
            if matches!(
                client_kind,
                TerminalClientKind::SystemTerminal | TerminalClientKind::DesktopApp
            ) {
                tokio::time::sleep(std::time::Duration::from_millis(
                    TERMINAL_VIEWER_DETACH_DEBOUNCE_MS,
                ))
                .await;
            }
            if let Err(error) = state
                .terminal_manager
                .unregister_viewer_if_epoch(terminal_id, client_kind, Some(epoch))
                .await
            {
                warn!(terminal_id = %terminal_id, error = %error, "terminal viewer disconnect cleanup failed");
            }
        });
    }

    if counts_as_desktop_client {
        let mut runtime = state.runtime.write().await;
        runtime.desktop_client_connections = runtime.desktop_client_connections.saturating_sub(1);
    }

    info!(
        socket_id = %socket_id,
        device_id = %state.config.backend.device_id,
        "desktop flutter client disconnected"
    );
    state.logger.info(format!(
        "desktop flutter client disconnected socket_id={} device_id={}",
        socket_id, state.config.backend.device_id
    ));
}

fn build_settings_sync_message(
    state: &AppState,
    auto_approve: bool,
    prefer_tmux_terminal: bool,
    local_ws_port: u16,
    logging_enabled: bool,
) -> serde_json::Value {
    serde_json::json!({
        "type": "settings.sync",
        "auto_approve_screen_share": auto_approve,
        "prefer_tmux_terminal": prefer_tmux_terminal,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::ai::{
        config::{
            AiLaunchConfig, ApprovalMode, ModelConfig, ModelKind, ProviderConfig, ProviderKind,
            SessionAgentRuntimeConfig, SirixConfig,
        },
        session::{AiSessionRecord, AiSessionRegistry},
    };
    use std::path::PathBuf;

    #[test]
    fn raw_terminal_filter_targets_approval_by_ai_session_when_terminal_id_is_absent() {
        let ai_session_id = Uuid::new_v4();
        let raw = serde_json::json!({
            "type": "ai.approval.request",
            "payload": {
                "ai_session_id": ai_session_id,
                "request_id": "request-1",
                "agent_id": "code-searcher",
                "capability_key": "builtin.shell"
            }
        })
        .to_string();

        assert_eq!(
            raw_terminal_forward_target(&raw),
            Some(RawTerminalForwardTarget::AiSession(ai_session_id))
        );
    }

    #[test]
    fn raw_terminal_filter_keeps_terminal_scoped_events_terminal_targeted() {
        let terminal_id = Uuid::new_v4();
        let raw = serde_json::json!({
            "type": "terminal.output",
            "payload": {
                "terminal_id": terminal_id,
                "data_base64": ""
            }
        })
        .to_string();

        assert_eq!(
            raw_terminal_forward_target(&raw),
            Some(RawTerminalForwardTarget::Terminal(terminal_id))
        );
    }

    #[tokio::test]
    async fn raw_terminal_filter_resolves_ai_session_to_attached_terminal() {
        let registry = AiSessionRegistry::new();
        let ai_session_id = Uuid::new_v4();
        let terminal_id = Uuid::new_v4();
        let other_terminal_id = Uuid::new_v4();
        let launch = test_launch_config();
        registry
            .insert(
                AiSessionRecord {
                    ai_session_id,
                    terminal_id,
                    cwd: "/tmp/workspace".to_string(),
                    agent_id: launch.agent.id.clone(),
                    model_id: launch.model.id.clone(),
                    mirrored_to_backend: false,
                },
                &launch,
                SessionAgentRuntimeConfig {
                    agent_id: launch.agent.id.clone(),
                    shell_mode: ApprovalMode::Ask,
                    builtin_tool_ids: Vec::new(),
                    effective_context_window: Some(32_000),
                },
            )
            .await;

        let raw = serde_json::json!({
            "type": "ai.approval.request",
            "payload": {
                "ai_session_id": ai_session_id,
                "request_id": "request-1",
                "capability_key": "builtin.shell"
            }
        })
        .to_string();

        assert!(
            should_forward_to_raw_terminal_socket_with_registry(&registry, &raw, terminal_id).await
        );
        assert!(
            !should_forward_to_raw_terminal_socket_with_registry(
                &registry,
                &raw,
                other_terminal_id
            )
            .await
        );
    }

    fn test_launch_config() -> AiLaunchConfig {
        let provider = ProviderConfig {
            id: "provider".to_string(),
            name: "Provider".to_string(),
            kind: ProviderKind::OpenAiCompatible,
            default_context_window: Some(32_000),
            base_url: "https://example.com/v1".to_string(),
            api_key_env: String::new(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: vec![ModelConfig {
                id: "model".to_string(),
                display_name: "Model".to_string(),
                model_kind: ModelKind::Text,
                context_window: Some(32_000),
                supports_images: false,
                supported_reasoning_efforts: None,
                enabled: true,
            }],
        };
        let mut agent = SirixConfig::default()
            .agents
            .into_iter()
            .next()
            .expect("default config should seed an agent");
        agent.id = "code-searcher".to_string();
        agent.provider_id = provider.id.clone();
        agent.model_id = provider.models[0].id.clone();
        AiLaunchConfig {
            effective_config: SirixConfig {
                providers: vec![provider.clone()],
                agents: vec![agent.clone()],
                ..SirixConfig::default()
            },
            agent,
            provider: provider.clone(),
            model: provider.models[0].clone(),
            session_providers: vec![provider],
            codex_home: PathBuf::from("/tmp/codex-home"),
            session_storage_dir: PathBuf::from("/tmp/session"),
            workspace_root: PathBuf::from("/tmp/workspace"),
            workspace_source: None,
        }
    }
}
