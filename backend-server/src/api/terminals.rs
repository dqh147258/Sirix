use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};
use uuid::Uuid;

use crate::{
    api::{
        error::{ApiError, ApiResult},
        resolve_user_id,
    },
    application::state::AppState,
};

#[derive(Debug, Serialize)]
pub struct TerminalSummary {
    pub id: Uuid,
    pub device_id: Uuid,
    pub title: String,
    pub shell: String,
    pub cwd: String,
    pub state: String,
    pub cols: i32,
    pub rows: i32,
    pub created_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
pub struct CreateTerminalRequest {
    pub target_device_id: Uuid,
    pub cols: i32,
    pub rows: i32,
    pub cwd: Option<String>,
    pub shell: Option<String>,
    pub title: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ListTerminalQuery {
    pub device_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
pub struct DesktopTerminalStateRequest {
    pub device_id: Uuid,
    pub state: String,
    pub title: Option<String>,
    pub shell: Option<String>,
    pub cwd: Option<String>,
    pub cols: Option<i32>,
    pub rows: Option<i32>,
    pub error_message: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TerminalOutputRequest {
    pub device_id: Uuid,
    pub data_base64: String,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum TerminalInboundMessage {
    #[serde(rename = "terminal.input")]
    Input { data_base64: String },
    #[serde(rename = "terminal.resize")]
    Resize { cols: i32, rows: i32 },
    #[serde(rename = "terminal.close")]
    Close,
    #[serde(rename = "terminal.ping")]
    Ping,
}

pub async fn create_terminal(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateTerminalRequest>,
) -> ApiResult<Json<TerminalSummary>> {
    let user_id = resolve_user_id(&headers, &state).await?;
    let target_row = state
        .postgres
        .query_opt(
            "SELECT user_id FROM devices WHERE id = $1",
            &[&payload.target_device_id],
        )
        .await
        .map_err(internal_error)?;

    let Some(target_row) = target_row else {
        return Err(ApiError::not_found(
            "DEVICE_NOT_FOUND",
            "target device not found",
        ));
    };

    let owner_id: Uuid = target_row.get("user_id");
    if owner_id != user_id {
        return Err(ApiError::forbidden(
            "DEVICE_NOT_OWNED",
            "current mvp allows only same-account devices",
        ));
    }

    if !state
        .is_device_online(payload.target_device_id)
        .await
        .map_err(|error| ApiError::internal("TERMINAL_INTERNAL", error.to_string()))?
    {
        return Err(ApiError::conflict(
            "DEVICE_OFFLINE",
            "target device is offline",
        ));
    }

    let terminal_id = Uuid::new_v4();
    let now = Utc::now();
    let title = payload
        .title
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "Terminal".to_string());
    let shell = payload
        .shell
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "default".to_string());
    let cwd = payload
        .cwd
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "~".to_string());
    let cols = payload.cols.clamp(20, 400);
    let rows = payload.rows.clamp(10, 200);

    state
        .postgres
        .execute(
            "INSERT INTO terminal_sessions (id, device_id, creator_user_id, title, shell, cwd, state, cols, rows, created_at, updated_at, closed_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
            &[
                &terminal_id,
                &payload.target_device_id,
                &user_id,
                &title,
                &shell,
                &cwd,
                &"opening",
                &cols,
                &rows,
                &now,
                &now,
                &Option::<DateTime<Utc>>::None,
            ],
        )
        .await
        .map_err(internal_error)?;

    state
        .postgres
        .execute(
            "INSERT INTO terminal_session_participants (session_id, user_id, client_type, joined_at) VALUES ($1,$2,$3,$4)",
            &[&terminal_id, &user_id, &"creator", &now],
        )
        .await
        .map_err(internal_error)?;

    let desktop_event = serde_json::json!({
        "type": "terminal.create",
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": now,
        "payload": {
            "terminal_id": terminal_id,
            "requester_user_id": user_id,
            "target_device_id": payload.target_device_id,
            "title": title,
            "shell": shell,
            "cwd": cwd,
            "cols": cols,
            "rows": rows,
        }
    });

    let subscribers = state
        .publish_desktop_event(payload.target_device_id, desktop_event.to_string())
        .await;
    if subscribers == 0 {
        let _ = state
            .postgres
            .execute(
                "UPDATE terminal_sessions SET state = $2, updated_at = $3, closed_at = $4 WHERE id = $1",
                &[&terminal_id, &"closed", &now, &Some(now)],
            )
            .await;
        return Err(ApiError::conflict(
            "DEVICE_OFFLINE",
            "desktop event stream unavailable",
        ));
    }

    Ok(Json(TerminalSummary {
        id: terminal_id,
        device_id: payload.target_device_id,
        title,
        shell,
        cwd,
        state: "opening".to_string(),
        cols,
        rows,
        created_at: now,
        closed_at: None,
    }))
}

pub async fn list_terminals(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ListTerminalQuery>,
) -> ApiResult<Json<Vec<TerminalSummary>>> {
    let user_id = resolve_user_id(&headers, &state).await?;
    let rows = match query.device_id {
        Some(device_id) => {
            state
                .postgres
                .query(
                    "SELECT t.id, t.device_id, t.title, t.shell, t.cwd, t.state, t.cols, t.rows, t.created_at, t.closed_at
                     FROM terminal_sessions t
                     JOIN devices d ON d.id = t.device_id
                     WHERE d.user_id = $1 AND t.device_id = $2 AND t.state <> 'closed'
                     ORDER BY t.updated_at DESC",
                    &[&user_id, &device_id],
                )
                .await
        }
        None => {
            state
                .postgres
                .query(
                    "SELECT t.id, t.device_id, t.title, t.shell, t.cwd, t.state, t.cols, t.rows, t.created_at, t.closed_at
                     FROM terminal_sessions t
                     JOIN devices d ON d.id = t.device_id
                     WHERE d.user_id = $1 AND t.state <> 'closed'
                     ORDER BY t.updated_at DESC",
                    &[&user_id],
                )
                .await
        }
    }
    .map_err(internal_error)?;

    let items = rows
        .into_iter()
        .map(|row| TerminalSummary {
            id: row.get("id"),
            device_id: row.get("device_id"),
            title: row.get("title"),
            shell: row.get("shell"),
            cwd: row.get("cwd"),
            state: row.get("state"),
            cols: row.get("cols"),
            rows: row.get("rows"),
            created_at: row.get("created_at"),
            closed_at: row.get("closed_at"),
        })
        .collect::<Vec<_>>();

    Ok(Json(items))
}

pub async fn close_terminal(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(terminal_id): Path<Uuid>,
) -> ApiResult<Json<serde_json::Value>> {
    let user_id = resolve_user_id(&headers, &state).await?;
    let terminal = load_terminal_for_user(&state, terminal_id, user_id).await?;
    let now = Utc::now();

    state
        .postgres
        .execute(
            "UPDATE terminal_sessions SET state = $2, updated_at = $3, closed_at = $4 WHERE id = $1",
            &[&terminal_id, &"closed", &now, &Some(now)],
        )
        .await
        .map_err(internal_error)?;

    let desktop_event = serde_json::json!({
        "type": "terminal.close",
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": now,
        "payload": {
            "terminal_id": terminal_id,
            "target_device_id": terminal.device_id,
        }
    });
    state
        .publish_desktop_event(terminal.device_id, desktop_event.to_string())
        .await;

    publish_terminal_state_event(
        &state,
        terminal_id,
        "terminal.closed",
        serde_json::json!({}),
    )
    .await;

    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn update_terminal_state(
    State(state): State<AppState>,
    Path(terminal_id): Path<Uuid>,
    Json(payload): Json<DesktopTerminalStateRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let row = state
        .postgres
        .query_opt(
            "SELECT device_id, title, shell, cwd, cols, rows FROM terminal_sessions WHERE id = $1",
            &[&terminal_id],
        )
        .await
        .map_err(internal_error)?;

    let Some(row) = row else {
        return Err(ApiError::not_found(
            "TERMINAL_NOT_FOUND",
            "terminal session not found",
        ));
    };
    let device_id: Uuid = row.get("device_id");
    if payload.device_id != device_id {
        return Err(ApiError::forbidden(
            "TERMINAL_NOT_FOUND",
            "device mismatch for terminal session",
        ));
    }

    let now = Utc::now();
    let title = payload.title.clone().unwrap_or_else(|| row.get("title"));
    let shell = payload.shell.clone().unwrap_or_else(|| row.get("shell"));
    let cwd = payload.cwd.clone().unwrap_or_else(|| row.get("cwd"));
    let cols = payload.cols.unwrap_or_else(|| row.get("cols"));
    let rows = payload.rows.unwrap_or_else(|| row.get("rows"));
    let closed_at = if payload.state == "closed" {
        Some(now)
    } else {
        None
    };

    state
        .postgres
        .execute(
            "UPDATE terminal_sessions SET title = $2, shell = $3, cwd = $4, state = $5, cols = $6, rows = $7, updated_at = $8, closed_at = COALESCE($9, closed_at) WHERE id = $1",
            &[&terminal_id, &title, &shell, &cwd, &payload.state, &cols, &rows, &now, &closed_at],
        )
        .await
        .map_err(internal_error)?;

    publish_terminal_state_event(
        &state,
        terminal_id,
        match payload.state.as_str() {
            "active" => "terminal.ready",
            "closed" => "terminal.closed",
            "error" => "terminal.error",
            _ => "terminal.updated",
        },
        serde_json::json!({
            "title": title,
            "shell": shell,
            "cwd": cwd,
            "state": payload.state,
            "cols": cols,
            "rows": rows,
            "error_message": payload.error_message,
        }),
    )
    .await;

    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn ingest_terminal_output(
    State(state): State<AppState>,
    Path(terminal_id): Path<Uuid>,
    Json(payload): Json<TerminalOutputRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let row = state
        .postgres
        .query_opt(
            "SELECT device_id FROM terminal_sessions WHERE id = $1",
            &[&terminal_id],
        )
        .await
        .map_err(internal_error)?;

    let Some(row) = row else {
        return Err(ApiError::not_found(
            "TERMINAL_NOT_FOUND",
            "terminal session not found",
        ));
    };
    let device_id: Uuid = row.get("device_id");
    if payload.device_id != device_id {
        return Err(ApiError::forbidden(
            "TERMINAL_NOT_FOUND",
            "device mismatch for terminal session",
        ));
    }

    publish_terminal_state_event(
        &state,
        terminal_id,
        "terminal.output",
        serde_json::json!({
            "data_base64": payload.data_base64,
        }),
    )
    .await;

    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn terminal_events_ws(
    headers: HeaderMap,
    Path(terminal_id): Path<Uuid>,
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Response {
    let user_id = match resolve_user_id(&headers, &state).await {
        Ok(user_id) => user_id,
        Err(_) => return axum::http::StatusCode::UNAUTHORIZED.into_response(),
    };

    let terminal = match load_terminal_for_user(&state, terminal_id, user_id).await {
        Ok(terminal) => terminal,
        Err(error) => return error.into_response(),
    };

    ws.on_upgrade(move |socket| {
        serve_terminal_socket(socket, state, terminal_id, terminal.device_id)
    })
}

async fn serve_terminal_socket(
    mut socket: WebSocket,
    state: AppState,
    terminal_id: Uuid,
    device_id: Uuid,
) {
    let mut receiver = state.subscribe_terminal_events(terminal_id).await;
    info!(terminal_id = %terminal_id, device_id = %device_id, "terminal websocket connected");

    if let Ok(row) = state
        .postgres
        .query_one(
            "SELECT title, shell, cwd, state, cols, rows, created_at, closed_at FROM terminal_sessions WHERE id = $1",
            &[&terminal_id],
        )
        .await
    {
        let ready = serde_json::json!({
            "type": "terminal.ready",
            "payload": {
                "terminal_id": terminal_id,
                "device_id": device_id,
                "title": row.get::<_, String>("title"),
                "shell": row.get::<_, String>("shell"),
                "cwd": row.get::<_, String>("cwd"),
                "state": row.get::<_, String>("state"),
                "cols": row.get::<_, i32>("cols"),
                "rows": row.get::<_, i32>("rows"),
                "created_at": row.get::<_, DateTime<Utc>>("created_at"),
                "closed_at": row.get::<_, Option<DateTime<Utc>>>("closed_at"),
            }
        });
        if socket.send(Message::Text(ready.to_string())).await.is_err() {
            return;
        }
    }

    loop {
        tokio::select! {
            inbound = socket.next() => {
                match inbound {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(message) = serde_json::from_str::<TerminalInboundMessage>(&text) {
                            match message {
                                TerminalInboundMessage::Input { data_base64 } => {
                                    let event = serde_json::json!({
                                        "type": "terminal.input",
                                        "event_id": Uuid::new_v4().to_string(),
                                        "timestamp": Utc::now(),
                                        "payload": {
                                            "terminal_id": terminal_id,
                                            "target_device_id": device_id,
                                            "data_base64": data_base64,
                                        }
                                    });
                                    state.publish_desktop_event(device_id, event.to_string()).await;
                                }
                                TerminalInboundMessage::Resize { cols, rows } => {
                                    let event = serde_json::json!({
                                        "type": "terminal.resize",
                                        "event_id": Uuid::new_v4().to_string(),
                                        "timestamp": Utc::now(),
                                        "payload": {
                                            "terminal_id": terminal_id,
                                            "target_device_id": device_id,
                                            "cols": cols,
                                            "rows": rows,
                                        }
                                    });
                                    state.publish_desktop_event(device_id, event.to_string()).await;
                                }
                                TerminalInboundMessage::Close => {
                                    let event = serde_json::json!({
                                        "type": "terminal.close",
                                        "event_id": Uuid::new_v4().to_string(),
                                        "timestamp": Utc::now(),
                                        "payload": {
                                            "terminal_id": terminal_id,
                                            "target_device_id": device_id,
                                        }
                                    });
                                    state.publish_desktop_event(device_id, event.to_string()).await;
                                }
                                TerminalInboundMessage::Ping => {
                                    if socket.send(Message::Text(serde_json::json!({"type": "terminal.pong"}).to_string())).await.is_err() {
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        if socket.send(Message::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Close(_))) => break,
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        warn!(terminal_id = %terminal_id, error = %error, "terminal websocket inbound error");
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
                        warn!(terminal_id = %terminal_id, error = %error, "terminal event receive failed");
                        break;
                    }
                }
            }
        }
    }

    info!(terminal_id = %terminal_id, "terminal websocket disconnected");
}

struct TerminalRow {
    device_id: Uuid,
}

async fn load_terminal_for_user(
    state: &AppState,
    terminal_id: Uuid,
    user_id: Uuid,
) -> ApiResult<TerminalRow> {
    let row = state
        .postgres
        .query_opt(
            "SELECT t.device_id
             FROM terminal_sessions t
             JOIN devices d ON d.id = t.device_id
             WHERE t.id = $1 AND d.user_id = $2",
            &[&terminal_id, &user_id],
        )
        .await
        .map_err(internal_error)?;

    let Some(row) = row else {
        return Err(ApiError::not_found(
            "TERMINAL_NOT_FOUND",
            "terminal session not found",
        ));
    };

    Ok(TerminalRow {
        device_id: row.get("device_id"),
    })
}

async fn publish_terminal_state_event(
    state: &AppState,
    terminal_id: Uuid,
    event_type: &str,
    payload: serde_json::Value,
) {
    let mut event_payload = serde_json::Map::new();
    event_payload.insert(
        "terminal_id".to_string(),
        serde_json::Value::String(terminal_id.to_string()),
    );
    if let serde_json::Value::Object(map) = payload {
        for (key, value) in map {
            event_payload.insert(key, value);
        }
    }
    let event = serde_json::json!({
        "type": event_type,
        "event_id": Uuid::new_v4().to_string(),
        "timestamp": Utc::now(),
        "payload": event_payload,
    });
    state
        .publish_terminal_event(terminal_id, event.to_string())
        .await;
}

fn internal_error(error: tokio_postgres::Error) -> ApiError {
    ApiError::internal("TERMINAL_INTERNAL", error.to_string())
}
