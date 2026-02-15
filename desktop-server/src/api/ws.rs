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
    info!("desktop flutter client connected to local websocket");

    let current_auto_approve = state.runtime.read().await.auto_approve_screen_share;
    let sync_message = serde_json::json!({
        "type": "settings.sync",
        "auto_approve_screen_share": current_auto_approve,
    });
    if socket
        .send(Message::Text(sync_message.to_string()))
        .await
        .is_err()
    {
        return;
    }

    loop {
        tokio::select! {
            incoming = socket.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<LocalWsInbound>(&text) {
                            Ok(LocalWsInbound::SettingsSetAutoApprove { auto_approve_screen_share }) => {
                                let mut runtime = state.runtime.write().await;
                                runtime.auto_approve_screen_share = auto_approve_screen_share;
                                let reply = serde_json::json!({
                                    "type": "settings.sync",
                                    "auto_approve_screen_share": runtime.auto_approve_screen_share,
                                });
                                if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                    break;
                                }
                            }
                            Ok(LocalWsInbound::AuthorizeResponse { session_id, decision }) => {
                                let approved = decision.eq_ignore_ascii_case("approve");
                                if let Some(sender) = state.pending_authorizations.lock().await.remove(&session_id) {
                                    let _ = sender.send(approved);
                                }
                                let reply = serde_json::json!({
                                    "type": "authorize.ack",
                                    "session_id": session_id,
                                    "accepted": approved,
                                });
                                if socket.send(Message::Text(reply.to_string())).await.is_err() {
                                    break;
                                }
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

    info!("desktop flutter client disconnected");
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
