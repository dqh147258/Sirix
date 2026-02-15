use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, State,
    },
    response::Response,
};
use futures_util::StreamExt;
use tracing::{info, warn};
use uuid::Uuid;

use crate::application::state::AppState;

pub async fn desktop_events_ws(
    Path(device_id): Path<Uuid>,
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(move |socket| serve_socket(socket, state, device_id))
}

async fn serve_socket(mut socket: WebSocket, state: AppState, device_id: Uuid) {
    let mut receiver = state.subscribe_desktop_events(device_id).await;
    info!(device_id = %device_id, "desktop event websocket connected");

    loop {
        tokio::select! {
            inbound = socket.next() => {
                match inbound {
                    Some(Ok(Message::Ping(payload))) => {
                        if socket.send(Message::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Close(_))) => break,
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        warn!(device_id = %device_id, error = %error, "desktop event websocket inbound error");
                        break;
                    }
                    None => break,
                }
            }
            outbound = receiver.recv() => {
                match outbound {
                    Ok(payload) => {
                        if socket.send(Message::Text(payload)).await.is_err() {
                            break;
                        }
                    }
                    Err(error) => {
                        warn!(device_id = %device_id, error = %error, "desktop event broadcast receive failed");
                        break;
                    }
                }
            }
        }
    }

    info!(device_id = %device_id, "desktop event websocket disconnected");
}
