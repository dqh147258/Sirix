use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    api::{
        error::{ApiError, ApiResult},
        resolve_user_id,
    },
    application::state::AppState,
};

#[derive(Debug, Deserialize)]
pub struct ListSessionEventsQuery {
    pub limit: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct SessionEventItem {
    pub event_type: String,
    pub created_at: DateTime<Utc>,
    pub payload: serde_json::Value,
}

pub async fn list_session_events(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
    Query(query): Query<ListSessionEventsQuery>,
) -> ApiResult<Json<Vec<SessionEventItem>>> {
    let user_id = resolve_user_id(&headers, &state).await?;

    let session_row = state
        .postgres
        .query_opt(
            "SELECT requester_user_id FROM share_sessions WHERE id = $1",
            &[&session_id],
        )
        .await
        .map_err(internal_error)?;

    let Some(session_row) = session_row else {
        return Err(ApiError::not_found(
            "SESSION_NOT_FOUND",
            "session not found",
        ));
    };

    let requester_user_id: Uuid = session_row.get("requester_user_id");
    if requester_user_id != user_id {
        return Err(ApiError::forbidden(
            "SESSION_NOT_ACTIVE",
            "session does not belong to current user",
        ));
    }

    let limit = i64::from(query.limit.unwrap_or(50).clamp(1, 200));
    let rows = state
        .postgres
        .query(
            "SELECT event_type, created_at, payload FROM session_events WHERE session_id = $1 ORDER BY created_at DESC LIMIT $2",
            &[&session_id, &limit],
        )
        .await
        .map_err(internal_error)?;

    let mut events = rows
        .into_iter()
        .map(|row| SessionEventItem {
            event_type: row.get("event_type"),
            created_at: row.get("created_at"),
            payload: row.get("payload"),
        })
        .collect::<Vec<_>>();

    events.reverse();
    Ok(Json(events))
}

fn internal_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal(
        "SESSION_EVENT_INTERNAL",
        format!("session event internal error: {error}"),
    )
}
