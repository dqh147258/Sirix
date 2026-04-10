use std::sync::Arc;

use anyhow::Context;
use chrono::Utc;
use redis::AsyncCommands;
use serde::{de::DeserializeOwned, Serialize};
use tokio_postgres::NoTls;
use tracing::{error, info};
use uuid::Uuid;

use crate::{
    application::{
        event_bus::EventBus,
        runtime_logging::{RuntimeLogStore, RuntimeSettings},
    },
    bootstrap::config::AppConfig,
    domain::{ScreenInfo, ScreenSnapshot},
};

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub runtime_settings: Arc<RuntimeSettings>,
    pub postgres: Arc<tokio_postgres::Client>,
    pub redis: Arc<redis::Client>,
    pub log_store: Arc<RuntimeLogStore>,
    pub desktop_event_bus: EventBus,
    pub mobile_event_bus: EventBus,
    pub terminal_event_bus: EventBus,
}

impl AppState {
    pub async fn new(
        config: AppConfig,
        runtime_settings: RuntimeSettings,
        log_store: Arc<RuntimeLogStore>,
    ) -> anyhow::Result<Self> {
        let (postgres, connection) = tokio_postgres::connect(&config.postgres.url, NoTls)
            .await
            .context("failed to connect postgres")?;

        tokio::spawn(async move {
            if let Err(error) = connection.await {
                error!(error = %error, "postgres connection task ended");
            }
        });

        postgres
            .batch_execute(include_str!("../../migrations/0001_init.sql"))
            .await
            .context("failed to run postgres bootstrap migration")?;
        postgres
            .batch_execute(include_str!("../../migrations/0002_ai_sessions.sql"))
            .await
            .context("failed to run postgres ai session migration")?;

        let redis = redis::Client::open(config.redis.url.clone())
            .context("failed to create redis client")?;
        {
            let mut connection = redis
                .get_async_connection()
                .await
                .context("failed to connect redis")?;
            let _: String = redis::cmd("PING")
                .query_async(&mut connection)
                .await
                .context("failed to ping redis")?;
        }

        info!("application state initialized with postgres and redis");

        Ok(Self {
            config: Arc::new(config),
            runtime_settings: Arc::new(runtime_settings),
            postgres: Arc::new(postgres),
            redis: Arc::new(redis),
            log_store,
            desktop_event_bus: EventBus::default(),
            mobile_event_bus: EventBus::default(),
            terminal_event_bus: EventBus::default(),
        })
    }

    pub async fn subscribe_desktop_events(
        &self,
        device_id: Uuid,
    ) -> tokio::sync::broadcast::Receiver<String> {
        self.desktop_event_bus
            .subscribe(&format!("device:{device_id}"))
            .await
    }

    pub async fn publish_desktop_event(&self, device_id: Uuid, payload: String) -> usize {
        self.desktop_event_bus
            .publish(&format!("device:{device_id}"), payload)
            .await
    }

    pub async fn subscribe_mobile_events(
        &self,
        user_id: Uuid,
    ) -> tokio::sync::broadcast::Receiver<String> {
        self.mobile_event_bus
            .subscribe(&format!("user:{user_id}"))
            .await
    }

    pub async fn publish_mobile_event(&self, user_id: Uuid, payload: String) -> usize {
        self.mobile_event_bus
            .publish(&format!("user:{user_id}"), payload)
            .await
    }

    pub async fn subscribe_terminal_events(
        &self,
        terminal_id: Uuid,
    ) -> tokio::sync::broadcast::Receiver<String> {
        self.terminal_event_bus
            .subscribe(&format!("terminal:{terminal_id}"))
            .await
    }

    pub async fn publish_terminal_event(&self, terminal_id: Uuid, payload: String) -> usize {
        self.terminal_event_bus
            .publish(&format!("terminal:{terminal_id}"), payload)
            .await
    }

    pub async fn store_access_token(&self, token: &str, user_id: Uuid) -> anyhow::Result<()> {
        let ttl_seconds = (self.config.auth.access_token_ttl_minutes * 60).max(60) as usize;
        self.store_token(token_key_access(token), user_id, ttl_seconds)
            .await
    }

    pub async fn store_refresh_token(&self, token: &str, user_id: Uuid) -> anyhow::Result<()> {
        let ttl_seconds = (self.config.auth.refresh_token_ttl_days * 24 * 60 * 60).max(60) as usize;
        self.store_token(token_key_refresh(token), user_id, ttl_seconds)
            .await
    }

    pub async fn resolve_access_user_id(&self, token: &str) -> anyhow::Result<Option<Uuid>> {
        self.resolve_token(token_key_access(token)).await
    }

    pub async fn resolve_refresh_user_id(&self, token: &str) -> anyhow::Result<Option<Uuid>> {
        self.resolve_token(token_key_refresh(token)).await
    }

    pub async fn cache_screens(
        &self,
        device_id: Uuid,
        screens: &[ScreenInfo],
    ) -> anyhow::Result<()> {
        self.cache_json(cache_key_screens(device_id), screens, 60 * 10)
            .await
    }

    pub async fn get_cached_screens(
        &self,
        device_id: Uuid,
    ) -> anyhow::Result<Option<Vec<ScreenInfo>>> {
        self.get_cached_json(cache_key_screens(device_id)).await
    }

    pub async fn cache_snapshots(
        &self,
        device_id: Uuid,
        snapshots: &[ScreenSnapshot],
        ttl_seconds: usize,
    ) -> anyhow::Result<()> {
        self.cache_json(cache_key_snapshots(device_id), snapshots, ttl_seconds)
            .await
    }

    pub async fn get_cached_snapshots(
        &self,
        device_id: Uuid,
    ) -> anyhow::Result<Option<Vec<ScreenSnapshot>>> {
        self.get_cached_json(cache_key_snapshots(device_id)).await
    }

    pub async fn set_device_presence(&self, device_id: Uuid, online: bool) -> anyhow::Result<()> {
        let mut connection = self.redis.get_async_connection().await?;
        let key = format!("presence:device:{device_id}");
        let value = if online { "online" } else { "offline" };
        let _: () = connection.set_ex(key, value, 60).await?;
        Ok(())
    }

    pub async fn is_device_online(&self, device_id: Uuid) -> anyhow::Result<bool> {
        let mut connection = self.redis.get_async_connection().await?;
        let key = format!("presence:device:{device_id}");
        let value: Option<String> = connection.get(key).await?;
        Ok(matches!(value.as_deref(), Some("online")))
    }

    pub async fn touch_last_seen(&self, device_id: Uuid) -> anyhow::Result<()> {
        let now = Utc::now();
        self.postgres
            .execute(
                "UPDATE devices SET last_seen_at = $2 WHERE id = $1",
                &[&device_id, &now],
            )
            .await?;
        self.set_device_presence(device_id, true).await
    }

    async fn store_token(
        &self,
        key: String,
        user_id: Uuid,
        ttl_seconds: usize,
    ) -> anyhow::Result<()> {
        let mut connection = self.redis.get_async_connection().await?;
        let _: () = connection
            .set_ex(key, user_id.to_string(), ttl_seconds)
            .await?;
        Ok(())
    }

    async fn resolve_token(&self, key: String) -> anyhow::Result<Option<Uuid>> {
        let mut connection = self.redis.get_async_connection().await?;
        let value: Option<String> = connection.get(key).await?;
        match value {
            Some(raw) => Ok(Uuid::parse_str(&raw).ok()),
            None => Ok(None),
        }
    }

    async fn cache_json<T: Serialize + ?Sized>(
        &self,
        key: String,
        value: &T,
        ttl_seconds: usize,
    ) -> anyhow::Result<()> {
        let mut connection = self.redis.get_async_connection().await?;
        let payload = serde_json::to_string(value)?;
        let _: () = connection.set_ex(key, payload, ttl_seconds).await?;
        Ok(())
    }

    async fn get_cached_json<T: DeserializeOwned>(&self, key: String) -> anyhow::Result<Option<T>> {
        let mut connection = self.redis.get_async_connection().await?;
        let payload: Option<String> = connection.get(key).await?;
        match payload {
            Some(raw) => Ok(Some(serde_json::from_str::<T>(&raw)?)),
            None => Ok(None),
        }
    }
}

fn token_key_access(token: &str) -> String {
    format!("auth:access:{token}")
}

fn token_key_refresh(token: &str) -> String {
    format!("auth:refresh:{token}")
}

fn cache_key_screens(device_id: Uuid) -> String {
    format!("device:screens:{device_id}")
}

fn cache_key_snapshots(device_id: Uuid) -> String {
    format!("device:snapshots:{device_id}")
}
