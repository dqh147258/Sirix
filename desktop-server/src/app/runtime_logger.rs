use std::{
    collections::VecDeque,
    sync::atomic::{AtomicBool, Ordering},
    sync::Mutex,
    time::Duration,
};

use chrono::Utc;
use reqwest::Client;
use serde::Serialize;
#[derive(Debug, Clone, Serialize)]
struct RuntimeLogEntry {
    timestamp: chrono::DateTime<Utc>,
    level: String,
    message: String,
    context: Option<serde_json::Value>,
}

pub struct RuntimeLogger {
    enabled: AtomicBool,
    endpoint: String,
    client: Client,
    pending: Mutex<VecDeque<RuntimeLogEntry>>,
}

impl RuntimeLogger {
    pub fn new(base_url: String, path: String) -> Self {
        Self {
            enabled: AtomicBool::new(true),
            endpoint: format!("{}{}", base_url.trim_end_matches('/'), path),
            client: Client::new(),
            pending: Mutex::new(VecDeque::new()),
        }
    }

    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Relaxed);
        if !enabled {
            let mut pending = self.pending.lock().expect("runtime logger mutex poisoned");
            pending.clear();
        }
    }

    pub fn info(&self, message: impl Into<String>) {
        self.log("INFO", message.into(), None);
    }

    pub fn warn(&self, message: impl Into<String>) {
        self.log("WARN", message.into(), None);
    }

    pub fn error(&self, message: impl Into<String>) {
        self.log("ERROR", message.into(), None);
    }

    fn log(&self, level: &str, message: String, context: Option<serde_json::Value>) {
        if !self.enabled.load(Ordering::Relaxed) {
            return;
        }

        println!("[DESKTOP_BACKEND][{level}] {message}");

        let entry = RuntimeLogEntry {
            timestamp: Utc::now(),
            level: level.to_string(),
            message,
            context,
        };
        let mut pending = self.pending.lock().expect("runtime logger mutex poisoned");
        pending.push_back(entry);
        while pending.len() > 5000 {
            pending.pop_front();
        }
    }

    pub fn spawn_flush_task(self: std::sync::Arc<Self>) {
        tokio::spawn(async move {
            loop {
                if let Err(error) = self.flush_once().await {
                    if self.enabled.load(Ordering::Relaxed) {
                        eprintln!("[DESKTOP_BACKEND][WARN] runtime log flush failed: {error}");
                    }
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        });
    }

    async fn flush_once(&self) -> anyhow::Result<()> {
        if !self.enabled.load(Ordering::Relaxed) {
            return Ok(());
        }

        let entries = {
            let pending = self.pending.lock().expect("runtime logger mutex poisoned");
            pending.iter().take(64).cloned().collect::<Vec<_>>()
        };

        if entries.is_empty() {
            return Ok(());
        }

        let response = self
            .client
            .post(&self.endpoint)
            .json(&serde_json::json!({
                "source": "desktop_backend",
                "entries": entries,
            }))
            .send()
            .await?;

        if !response.status().is_success() {
            anyhow::bail!("backend returned status {}", response.status());
        }

        let mut pending = self.pending.lock().expect("runtime logger mutex poisoned");
        let drain_count = entries.len().min(pending.len());
        pending.drain(..drain_count);
        Ok(())
    }
}
