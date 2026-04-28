use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use chrono::Utc;
use serde::Serialize;
use serde_json::Value;

const LOCAL_API_BASE_ENV: &str = "SIRIX_LOCAL_API_BASE";
const RUNTIME_LOGS_ENDPOINT_ENV: &str = "SIRIX_RUNTIME_LOGS_ENDPOINT";
const DEFAULT_LOCAL_RUNTIME_LOGS_PATH: &str = "/runtime/logs";
const MAX_PENDING_ENTRIES: usize = 5_000;
const FLUSH_BATCH_SIZE: usize = 64;

static LOGGER: OnceLock<Arc<SirixRuntimeLogger>> = OnceLock::new();

#[derive(Debug, Clone, Serialize)]
struct RuntimeLogEntry {
    timestamp: chrono::DateTime<Utc>,
    level: String,
    message: String,
    context: Option<Value>,
}

struct SirixRuntimeLogger {
    endpoint: String,
    client: reqwest::Client,
    pending: Mutex<VecDeque<RuntimeLogEntry>>,
    flush_scheduled: AtomicBool,
    flush_in_progress: AtomicBool,
}

impl SirixRuntimeLogger {
    fn new(endpoint: String) -> Self {
        Self {
            endpoint,
            client: reqwest::Client::new(),
            pending: Mutex::new(VecDeque::new()),
            flush_scheduled: AtomicBool::new(false),
            flush_in_progress: AtomicBool::new(false),
        }
    }

    fn enqueue(self: &Arc<Self>, level: &str, message: String, context: Option<Value>) {
        {
            let mut pending = self
                .pending
                .lock()
                .expect("sirix runtime logger mutex poisoned");
            pending.push_back(RuntimeLogEntry {
                timestamp: Utc::now(),
                level: level.to_string(),
                message,
                context,
            });
            while pending.len() > MAX_PENDING_ENTRIES {
                pending.pop_front();
            }
        }
        self.schedule_flush_soon();
    }

    fn schedule_flush_soon(self: &Arc<Self>) {
        if self.flush_scheduled.swap(true, Ordering::AcqRel) {
            return;
        }
        let logger = Arc::clone(self);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(25)).await;
            if let Err(error) = logger.flush_once().await {
                tracing::warn!(error = %error, "failed to flush Sirix CLI runtime logs");
            }
            logger.flush_scheduled.store(false, Ordering::Release);
        });
    }

    fn spawn_periodic_flush(self: &Arc<Self>) {
        let logger = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                if let Err(error) = logger.flush_once().await {
                    tracing::warn!(error = %error, "failed to flush Sirix CLI runtime logs");
                }
            }
        });
    }

    async fn flush_once(&self) -> anyhow::Result<()> {
        if self.flush_in_progress.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let _flush_guard = FlushInProgressGuard(&self.flush_in_progress);
        let entries = {
            let pending = self
                .pending
                .lock()
                .expect("sirix runtime logger mutex poisoned");
            pending
                .iter()
                .take(FLUSH_BATCH_SIZE)
                .cloned()
                .collect::<Vec<_>>()
        };
        if entries.is_empty() {
            return Ok(());
        }

        let response = self
            .client
            .post(&self.endpoint)
            .json(&serde_json::json!({
                "source": "sirix_cli",
                "entries": entries,
            }))
            .send()
            .await?;
        if !response.status().is_success() {
            anyhow::bail!("runtime log endpoint returned status {}", response.status());
        }

        let mut pending = self
            .pending
            .lock()
            .expect("sirix runtime logger mutex poisoned");
        let drain_count = FLUSH_BATCH_SIZE.min(pending.len());
        pending.drain(..drain_count);
        Ok(())
    }
}

struct FlushInProgressGuard<'a>(&'a AtomicBool);

impl Drop for FlushInProgressGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

pub(crate) fn init_from_env() {
    let Some(endpoint) = runtime_logs_endpoint_from_env() else {
        return;
    };
    let logger = Arc::new(SirixRuntimeLogger::new(endpoint));
    if LOGGER.set(Arc::clone(&logger)).is_ok() {
        logger.spawn_periodic_flush();
        info(
            "[SIRIX_CLI_RUNTIME_LOG] logger initialized",
            Some(serde_json::json!({
                "pid": std::process::id(),
            })),
        );
    }
}

pub(crate) fn info(message: impl Into<String>, context: Option<Value>) {
    log("INFO", message.into(), context);
}

pub(crate) fn warn(message: impl Into<String>, context: Option<Value>) {
    log("WARN", message.into(), context);
}

fn log(level: &str, message: String, context: Option<Value>) {
    if let Some(logger) = LOGGER.get() {
        logger.enqueue(level, message, context);
    }
}

fn runtime_logs_endpoint_from_env() -> Option<String> {
    if let Ok(endpoint) = std::env::var(RUNTIME_LOGS_ENDPOINT_ENV) {
        let trimmed = endpoint.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }

    let base = std::env::var(LOCAL_API_BASE_ENV).ok()?;
    let trimmed = base.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(format!(
        "{}{}",
        trimmed.trim_end_matches('/'),
        DEFAULT_LOCAL_RUNTIME_LOGS_PATH
    ))
}
