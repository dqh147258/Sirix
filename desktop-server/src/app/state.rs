use std::{collections::HashMap, sync::Arc};

use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio::sync::{broadcast, oneshot, Mutex, RwLock};

use crate::app::{
    ai::{approval::AiApprovalRegistry, config::SirixConfigStore, session::AiSessionRegistry},
    auth::AuthSessionStore,
    runtime_logger::RuntimeLogger,
    terminal::manager::TerminalManager,
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
    pub sirix_config_store: Arc<SirixConfigStore>,
    pub ai_session_registry: Arc<AiSessionRegistry>,
    pub ai_approval_registry: Arc<AiApprovalRegistry>,
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
        let sirix_config_store =
            Arc::new(SirixConfigStore::new().expect("failed to initialize ~/.sirix config store"));
        let approval_storage_dir = sirix_config_store
            .sirix_home()
            .join("runtime")
            .join("approvals");
        Self {
            terminal_manager: Arc::new(TerminalManager::new(
                config.backend.base_url.clone(),
                config.backend.device_id.clone(),
                local_events.clone(),
                sirix_config_store.sirix_home().to_path_buf(),
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
            sirix_config_store,
            ai_session_registry: Arc::new(AiSessionRegistry::new()),
            ai_approval_registry: Arc::new(
                AiApprovalRegistry::new(approval_storage_dir)
                    .expect("failed to initialize ai approval registry"),
            ),
        }
    }
}
