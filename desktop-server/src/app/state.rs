use std::{collections::HashMap, sync::Arc};

use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio::sync::{broadcast, oneshot, Mutex, RwLock};

use crate::app::{
    auth::AuthSessionStore, runtime_logger::RuntimeLogger, terminal::manager::TerminalManager,
};
use crate::bootstrap::config::AppConfig;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub logger: Arc<RuntimeLogger>,
    pub runtime: Arc<RwLock<RuntimeState>>,
    pub local_events: broadcast::Sender<String>,
    pub pending_authorizations: Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>>,
    pub terminal_manager: Arc<TerminalManager>,
    pub auth_session_store: AuthSessionStore,
}

#[derive(Debug, Clone, Serialize)]
pub struct RuntimeState {
    pub local_ws_port: u16,
    pub desktop_client_connections: usize,
    pub auto_approve_screen_share: bool,
    pub logging_enabled: bool,
    pub backend_event_stream_connected: bool,
    pub backend_last_healthy_at: Option<DateTime<Utc>>,
}

impl AppState {
    pub fn new(config: AppConfig, local_ws_port: u16) -> Self {
        let (local_events, _) = broadcast::channel(256);
        let logger = Arc::new(RuntimeLogger::new(
            config.backend.base_url.clone(),
            config.backend.runtime_logs_path.clone(),
        ));
        Self {
            terminal_manager: Arc::new(TerminalManager::new(
                config.backend.base_url.clone(),
                config.backend.device_id.clone(),
                local_events.clone(),
            )),
            auth_session_store: AuthSessionStore::new(config.backend.base_url.clone()),
            config: Arc::new(config),
            logger,
            runtime: Arc::new(RwLock::new(RuntimeState {
                local_ws_port,
                desktop_client_connections: 0,
                auto_approve_screen_share: false,
                logging_enabled: true,
                backend_event_stream_connected: false,
                backend_last_healthy_at: None,
            })),
            local_events,
            pending_authorizations: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}
