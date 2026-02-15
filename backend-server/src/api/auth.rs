use axum::{extract::State, Json};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tracing::info;
use uuid::Uuid;

use crate::{
    api::error::{ApiError, ApiResult},
    application::{auth as auth_service, state::AppState},
    domain::User,
};

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
    pub client_type: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RefreshRequest {
    pub refresh_token: String,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub user_id: Uuid,
    pub username: String,
    pub access_token: String,
    pub refresh_token: String,
}

pub async fn register(
    State(state): State<AppState>,
    Json(payload): Json<RegisterRequest>,
) -> ApiResult<Json<AuthResponse>> {
    if payload.username.trim().is_empty() || payload.password.len() < 8 {
        return Err(ApiError::bad_request(
            "AUTH_INVALID_CREDENTIALS",
            "username must not be empty and password must contain at least 8 chars",
        ));
    }

    let username = payload.username.trim().to_lowercase();

    if user_by_username(&state, &username)
        .await
        .map_err(internal_auth_error)?
        .is_some()
    {
        return Err(ApiError::conflict(
            "AUTH_USERNAME_EXISTS",
            "username already exists",
        ));
    }

    let hashed = auth_service::hash_password(&payload.password).map_err(|_| {
        ApiError::bad_request("AUTH_INVALID_CREDENTIALS", "failed to process password")
    })?;

    let user = User {
        id: Uuid::new_v4(),
        username: username.clone(),
        password_hash: hashed,
        created_at: Utc::now(),
    };

    state
        .postgres
        .execute(
            "INSERT INTO users (id, username, password_hash, created_at) VALUES ($1, $2, $3, $4)",
            &[
                &user.id,
                &user.username,
                &user.password_hash,
                &user.created_at,
            ],
        )
        .await
        .map_err(internal_auth_error)?;

    let (access_token, refresh_token) = auth_service::build_token_pair();
    state
        .store_access_token(&access_token, user.id)
        .await
        .map_err(internal_auth_error)?;
    state
        .store_refresh_token(&refresh_token, user.id)
        .await
        .map_err(internal_auth_error)?;

    info!(user_id = %user.id, "registered user");

    Ok(Json(AuthResponse {
        user_id: user.id,
        username,
        access_token,
        refresh_token,
    }))
}

pub async fn login(
    State(state): State<AppState>,
    Json(payload): Json<LoginRequest>,
) -> ApiResult<Json<AuthResponse>> {
    if payload.username.trim().is_empty() || payload.password.is_empty() {
        return Err(ApiError::bad_request(
            "AUTH_INVALID_CREDENTIALS",
            "username and password are required",
        ));
    }

    let username = payload.username.trim().to_lowercase();
    let Some(user) = user_by_username(&state, &username)
        .await
        .map_err(internal_auth_error)?
    else {
        return Err(ApiError::unauthorized(
            "AUTH_INVALID_CREDENTIALS",
            "invalid username or password",
        ));
    };

    if !auth_service::verify_password(&payload.password, &user.password_hash) {
        return Err(ApiError::unauthorized(
            "AUTH_INVALID_CREDENTIALS",
            "invalid username or password",
        ));
    }

    let (access_token, refresh_token) = auth_service::build_token_pair();
    state
        .store_access_token(&access_token, user.id)
        .await
        .map_err(internal_auth_error)?;
    state
        .store_refresh_token(&refresh_token, user.id)
        .await
        .map_err(internal_auth_error)?;

    info!(
        user_id = %user.id,
        client_type = %payload.client_type.unwrap_or_else(|| "unknown".to_string()),
        "user login"
    );

    Ok(Json(AuthResponse {
        user_id: user.id,
        username: user.username,
        access_token,
        refresh_token,
    }))
}

pub async fn refresh(
    State(state): State<AppState>,
    Json(payload): Json<RefreshRequest>,
) -> ApiResult<Json<AuthResponse>> {
    let Some(user_id) = state
        .resolve_refresh_user_id(&payload.refresh_token)
        .await
        .map_err(internal_auth_error)?
    else {
        return Err(ApiError::unauthorized(
            "AUTH_TOKEN_EXPIRED",
            "refresh token is invalid",
        ));
    };

    let user_row = state
        .postgres
        .query_opt(
            "SELECT id, username, password_hash, created_at FROM users WHERE id = $1",
            &[&user_id],
        )
        .await
        .map_err(internal_auth_error)?;

    let Some(row) = user_row else {
        return Err(ApiError::unauthorized(
            "AUTH_TOKEN_EXPIRED",
            "refresh token is invalid",
        ));
    };

    let user = row_to_user(&row);

    let (access_token, refresh_token) = auth_service::build_token_pair();
    state
        .store_access_token(&access_token, user.id)
        .await
        .map_err(internal_auth_error)?;
    state
        .store_refresh_token(&refresh_token, user.id)
        .await
        .map_err(internal_auth_error)?;

    Ok(Json(AuthResponse {
        user_id: user.id,
        username: user.username,
        access_token,
        refresh_token,
    }))
}

async fn user_by_username(state: &AppState, username: &str) -> anyhow::Result<Option<User>> {
    let row = state
        .postgres
        .query_opt(
            "SELECT id, username, password_hash, created_at FROM users WHERE username = $1",
            &[&username],
        )
        .await?;

    Ok(row.map(|row| row_to_user(&row)))
}

fn row_to_user(row: &tokio_postgres::Row) -> User {
    User {
        id: row.get::<_, Uuid>("id"),
        username: row.get::<_, String>("username"),
        password_hash: row.get::<_, String>("password_hash"),
        created_at: row.get::<_, DateTime<Utc>>("created_at"),
    }
}

fn internal_auth_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal("AUTH_INTERNAL", format!("internal auth error: {error}"))
}
