use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tracing::info;
use uuid::Uuid;

use crate::{
    api::{
        error::{ApiError, ApiResult},
        resolve_user_id,
    },
    application::state::AppState,
    domain::{Device, ScreenInfo, ScreenSnapshot},
};

#[derive(Debug, Deserialize)]
pub struct RegisterDeviceRequest {
    pub device_name: String,
    pub platform: String,
    pub client_version: String,
    pub preferred_device_id: Option<Uuid>,
}

#[derive(Debug, Serialize)]
pub struct DeviceResponse {
    pub id: Uuid,
    pub device_name: String,
    pub platform: String,
    pub client_version: String,
    pub auto_approve_screen_share: bool,
    pub last_seen_at: chrono::DateTime<Utc>,
    pub online: bool,
}

#[derive(Debug, Deserialize)]
pub struct UpdateDeviceSettingsRequest {
    pub auto_approve_screen_share: bool,
}

#[derive(Debug, Serialize)]
pub struct DeviceSettingsResponse {
    pub device_id: Uuid,
    pub auto_approve_screen_share: bool,
}

#[derive(Debug, Default, Deserialize)]
pub struct DeviceSnapshotsQuery {
    pub refresh: Option<bool>,
}

pub async fn register_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<RegisterDeviceRequest>,
) -> ApiResult<Json<DeviceResponse>> {
    let user_id = resolve_user_id(&headers, &state).await?;

    let now = Utc::now();
    let device_id = payload.preferred_device_id.unwrap_or_else(Uuid::new_v4);

    let existing = state
        .postgres
        .query_opt(
            "SELECT user_id, auto_approve_screen_share, created_at FROM devices WHERE id = $1",
            &[&device_id],
        )
        .await
        .map_err(internal_device_error)?;

    let preferred_device_id = payload.preferred_device_id;

    let (device, action): (Device, &'static str) = if let Some(row) = existing {
        let owner_user_id: Uuid = row.get("user_id");
        let created_at: DateTime<Utc> = row.get("created_at");
        if owner_user_id != user_id {
            if preferred_device_id.is_none() {
                return Err(ApiError::conflict(
                    "DEVICE_ID_CONFLICT",
                    "preferred device id already belongs to another user",
                ));
            }

            state
                .postgres
                .execute(
                    "UPDATE devices SET user_id = $2, device_name = $3, platform = $4, client_version = $5, auto_approve_screen_share = false, last_seen_at = $6 WHERE id = $1",
                    &[
                        &device_id,
                        &user_id,
                        &payload.device_name,
                        &payload.platform,
                        &payload.client_version,
                        &now,
                    ],
                )
                .await
                .map_err(internal_device_error)?;

            (
                Device {
                    id: device_id,
                    user_id,
                    device_name: payload.device_name,
                    platform: payload.platform,
                    client_version: payload.client_version,
                    auto_approve_screen_share: false,
                    last_seen_at: now,
                    created_at,
                },
                "claimed",
            )
        } else {
            let auto_approve_screen_share: bool = row.get("auto_approve_screen_share");

            state
                .postgres
                .execute(
                    "UPDATE devices SET device_name = $2, platform = $3, client_version = $4, last_seen_at = $5 WHERE id = $1",
                    &[
                        &device_id,
                        &payload.device_name,
                        &payload.platform,
                        &payload.client_version,
                        &now,
                    ],
                )
                .await
                .map_err(internal_device_error)?;

            (
                Device {
                    id: device_id,
                    user_id,
                    device_name: payload.device_name,
                    platform: payload.platform,
                    client_version: payload.client_version,
                    auto_approve_screen_share,
                    last_seen_at: now,
                    created_at,
                },
                "updated",
            )
        }
    } else {
        let created_device = Device {
            id: device_id,
            user_id,
            device_name: payload.device_name,
            platform: payload.platform,
            client_version: payload.client_version,
            auto_approve_screen_share: false,
            last_seen_at: now,
            created_at: now,
        };

        state
            .postgres
            .execute(
                "INSERT INTO devices (id, user_id, device_name, platform, client_version, auto_approve_screen_share, last_seen_at, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
                &[
                    &created_device.id,
                    &created_device.user_id,
                    &created_device.device_name,
                    &created_device.platform,
                    &created_device.client_version,
                    &created_device.auto_approve_screen_share,
                    &created_device.last_seen_at,
                    &created_device.created_at,
                ],
            )
            .await
            .map_err(internal_device_error)?;

        (created_device, "created")
    };

    let screens = default_screens();
    let snapshots = build_snapshots(&screens, now);

    state
        .cache_screens(device.id, &screens)
        .await
        .map_err(internal_device_error)?;
    state
        .cache_snapshots(device.id, &snapshots, 60 * 5)
        .await
        .map_err(internal_device_error)?;
    state
        .set_device_presence(device.id, true)
        .await
        .map_err(internal_device_error)?;

    info!(
        device_id = %device.id,
        user_id = %user_id,
        action,
        "device registered"
    );

    Ok(Json(DeviceResponse {
        id: device.id,
        device_name: device.device_name,
        platform: device.platform,
        client_version: device.client_version,
        auto_approve_screen_share: device.auto_approve_screen_share,
        last_seen_at: device.last_seen_at,
        online: true,
    }))
}

pub async fn list_my_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> ApiResult<Json<Vec<DeviceResponse>>> {
    let user_id = resolve_user_id(&headers, &state).await?;

    let rows = state
        .postgres
        .query(
            "SELECT id, device_name, platform, client_version, auto_approve_screen_share, last_seen_at FROM devices WHERE user_id = $1 ORDER BY created_at DESC",
            &[&user_id],
        )
        .await
        .map_err(internal_device_error)?;

    let mut devices = Vec::with_capacity(rows.len());
    for row in rows {
        let id = row.get::<_, Uuid>("id");
        let online = state
            .is_device_online(id)
            .await
            .map_err(internal_device_error)?;
        devices.push(DeviceResponse {
            id,
            device_name: row.get::<_, String>("device_name"),
            platform: row.get::<_, String>("platform"),
            client_version: row.get::<_, String>("client_version"),
            auto_approve_screen_share: row.get::<_, bool>("auto_approve_screen_share"),
            last_seen_at: row.get::<_, DateTime<Utc>>("last_seen_at"),
            online,
        });
    }

    Ok(Json(devices))
}

pub async fn update_device_settings(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<Uuid>,
    Json(payload): Json<UpdateDeviceSettingsRequest>,
) -> ApiResult<Json<DeviceSettingsResponse>> {
    let user_id = resolve_user_id(&headers, &state).await?;

    ensure_device_owner(&state, device_id, user_id).await?;

    state
        .postgres
        .execute(
            "UPDATE devices SET auto_approve_screen_share = $2, last_seen_at = $3 WHERE id = $1",
            &[&device_id, &payload.auto_approve_screen_share, &Utc::now()],
        )
        .await
        .map_err(internal_device_error)?;

    Ok(Json(DeviceSettingsResponse {
        device_id,
        auto_approve_screen_share: payload.auto_approve_screen_share,
    }))
}

pub async fn list_device_screens(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<Uuid>,
) -> ApiResult<Json<Vec<ScreenInfo>>> {
    let user_id = resolve_user_id(&headers, &state).await?;
    ensure_device_owner(&state, device_id, user_id).await?;

    if let Some(cached) = state
        .get_cached_screens(device_id)
        .await
        .map_err(internal_device_error)?
    {
        return Ok(Json(cached));
    }

    let screens = default_screens();
    state
        .cache_screens(device_id, &screens)
        .await
        .map_err(internal_device_error)?;

    Ok(Json(screens))
}

pub async fn list_device_snapshots(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<Uuid>,
    Query(query): Query<DeviceSnapshotsQuery>,
) -> ApiResult<Json<Vec<ScreenSnapshot>>> {
    let user_id = resolve_user_id(&headers, &state).await?;
    ensure_device_owner(&state, device_id, user_id).await?;

    let cached_before = state
        .get_cached_snapshots(device_id)
        .await
        .map_err(internal_device_error)?;

    if query.refresh.unwrap_or(false) {
        let previous_latest = latest_snapshot_captured_at(cached_before.as_deref());
        let refresh_event = serde_json::json!({
            "type": "device.snapshots.refresh",
            "event_id": Uuid::new_v4().to_string(),
            "timestamp": Utc::now(),
            "payload": {
                "device_id": device_id,
                "reason": "mobile_snapshot_refresh",
            }
        });

        let subscribers = state
            .publish_desktop_event(device_id, refresh_event.to_string())
            .await;

        if subscribers > 0 {
            for _ in 0..12 {
                tokio::time::sleep(Duration::from_millis(250)).await;
                if let Some(cached) = state
                    .get_cached_snapshots(device_id)
                    .await
                    .map_err(internal_device_error)?
                {
                    if latest_snapshot_captured_at(Some(&cached)) > previous_latest {
                        return Ok(Json(cached));
                    }
                }
            }
        }

        if let Some(cached) = state
            .get_cached_snapshots(device_id)
            .await
            .map_err(internal_device_error)?
        {
            return Ok(Json(cached));
        }
    }

    if let Some(cached) = cached_before {
        return Ok(Json(cached));
    }

    let screens = state
        .get_cached_screens(device_id)
        .await
        .map_err(internal_device_error)?
        .unwrap_or_else(default_screens);
    let snapshots = build_snapshots(&screens, Utc::now());

    state
        .cache_snapshots(device_id, &snapshots, 60 * 5)
        .await
        .map_err(internal_device_error)?;

    Ok(Json(snapshots))
}

async fn ensure_device_owner(state: &AppState, device_id: Uuid, user_id: Uuid) -> ApiResult<()> {
    let row = state
        .postgres
        .query_opt("SELECT user_id FROM devices WHERE id = $1", &[&device_id])
        .await
        .map_err(internal_device_error)?;

    let Some(row) = row else {
        return Err(ApiError::not_found("DEVICE_NOT_FOUND", "device not found"));
    };

    let owner: Uuid = row.get("user_id");
    if owner != user_id {
        return Err(ApiError::forbidden(
            "DEVICE_NOT_OWNED",
            "device does not belong to current user",
        ));
    }

    Ok(())
}

fn default_screens() -> Vec<ScreenInfo> {
    vec![
        ScreenInfo {
            screen_id: "display-1".to_string(),
            name: "Display 1".to_string(),
            width: 1920,
            height: 1080,
            is_primary: true,
        },
        ScreenInfo {
            screen_id: "display-2".to_string(),
            name: "Display 2".to_string(),
            width: 2560,
            height: 1080,
            is_primary: false,
        },
    ]
}

fn latest_snapshot_captured_at(snapshots: Option<&[ScreenSnapshot]>) -> Option<DateTime<Utc>> {
    snapshots.and_then(|items| items.iter().map(|item| item.captured_at).max())
}

fn build_snapshots(screens: &[ScreenInfo], captured_at: DateTime<Utc>) -> Vec<ScreenSnapshot> {
    screens
        .iter()
        .map(|screen| {
            let width = 480u32;
            let ratio = screen.width as f64 / screen.height as f64;
            let height = ((width as f64) / ratio).round().max(240.0) as u32;
            ScreenSnapshot {
                screen_id: screen.screen_id.clone(),
                captured_at,
                width,
                height,
                preview_base64: String::new(),
            }
        })
        .collect()
}

fn internal_device_error(error: impl std::fmt::Display) -> ApiError {
    ApiError::internal("DEVICE_INTERNAL", format!("device internal error: {error}"))
}
