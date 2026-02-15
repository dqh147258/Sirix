use std::{collections::HashMap, sync::Arc};

use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio::sync::{broadcast, oneshot, Mutex, RwLock};

use crate::bootstrap::config::AppConfig;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub runtime: Arc<RwLock<RuntimeState>>,
    pub local_events: broadcast::Sender<String>,
    pub pending_authorizations: Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RuntimeState {
    pub local_ws_port: u16,
    pub desktop_client_connections: usize,
    pub auto_approve_screen_share: bool,
    pub backend_last_healthy_at: Option<DateTime<Utc>>,
}

impl AppState {
    pub fn new(config: AppConfig, local_ws_port: u16) -> Self {
        let (local_events, _) = broadcast::channel(256);
        Self {
            config: Arc::new(config),
            runtime: Arc::new(RwLock::new(RuntimeState {
                local_ws_port,
                desktop_client_connections: 0,
                auto_approve_screen_share: false,
                backend_last_healthy_at: None,
            })),
            local_events,
            pending_authorizations: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}
