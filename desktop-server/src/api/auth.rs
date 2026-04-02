use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use serde::Deserialize;

use crate::app::{auth::AuthSession, state::AppState};

#[derive(Debug, Deserialize)]
pub struct CredentialRequest {
    pub username: String,
    pub password: String,
}

pub async fn get_session(State(state): State<AppState>) -> Result<impl IntoResponse, ApiError> {
    let session = match state.auth_session_store.refresh_current_session().await {
        Ok(session) => session,
        Err(error) => {
            state
                .logger
                .warn(format!("desktop auth session refresh failed: {error}"));
            None
        }
    };

    match session {
        Some(session) => Ok((StatusCode::OK, Json(session)).into_response()),
        None => Ok(StatusCode::NO_CONTENT.into_response()),
    }
}

pub async fn login(
    State(state): State<AppState>,
    Json(payload): Json<CredentialRequest>,
) -> Result<Json<AuthSession>, ApiError> {
    let session = state
        .auth_session_store
        .login(payload.username.trim(), &payload.password)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(session))
}

pub async fn register(
    State(state): State<AppState>,
    Json(payload): Json<CredentialRequest>,
) -> Result<Json<AuthSession>, ApiError> {
    let session = state
        .auth_session_store
        .register(payload.username.trim(), &payload.password)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(session))
}

pub async fn logout(State(state): State<AppState>) -> Result<StatusCode, ApiError> {
    state
        .auth_session_store
        .clear()
        .await
        .map_err(ApiError::internal)?;
    Ok(StatusCode::NO_CONTENT)
}

pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn internal(error: anyhow::Error) -> Self {
        Self {
            status: StatusCode::BAD_GATEWAY,
            message: error.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (
            self.status,
            Json(serde_json::json!({
                "error": self.message,
            })),
        )
            .into_response()
    }
}
