use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::HeaderMap,
    response::{IntoResponse, Response},
};
use futures_util::StreamExt;
use tracing::{info, warn};

use crate::{api::resolve_user_id, application::state::AppState};

pub async fn mobile_events_ws(
    headers: HeaderMap,
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Response {
    let user_id = match resolve_user_id(&headers, &state).await {
        Ok(user_id) => user_id,
        Err(_) => {
            return axum::http::StatusCode::UNAUTHORIZED.into_response();
        }
    };

    ws.on_upgrade(move |socket| serve_socket(socket, state, user_id))
}

async fn serve_socket(mut socket: WebSocket, state: AppState, user_id: uuid::Uuid) {
    let mut receiver = state.subscribe_mobile_events(user_id).await;
    info!(user_id = %user_id, "mobile event websocket connected");

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
                        warn!(user_id = %user_id, error = %error, "mobile event websocket inbound error");
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
                        warn!(user_id = %user_id, error = %error, "mobile event broadcast receive failed");
                        break;
                    }
                }
            }
        }
    }

    info!(user_id = %user_id, "mobile event websocket disconnected");
}
