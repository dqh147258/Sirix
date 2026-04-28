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

#[derive(Debug, Clone)]
struct PendingRuntimeLogEntry {
    source: String,
    entry: RuntimeLogEntry,
}

pub struct RuntimeLogger {
    enabled: AtomicBool,
    endpoint: String,
    client: Client,
    pending: Mutex<VecDeque<PendingRuntimeLogEntry>>,
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

    /// Queue a log entry that originated outside the desktop-server process
    /// but should share its backend runtime-log transport.  This is used by the
    /// Sirix CLI running inside a managed PTY: the CLI only knows the local
    /// Desktop API URL, while desktop-server already knows the backend runtime
    /// log endpoint and retry policy.
    pub fn ingest_external(
        &self,
        source: impl Into<String>,
        level: Option<String>,
        message: String,
        context: Option<serde_json::Value>,
        timestamp: Option<chrono::DateTime<Utc>>,
    ) {
        let level = level.unwrap_or_else(|| "INFO".to_string());
        self.enqueue(
            source.into(),
            level.to_uppercase(),
            message,
            context,
            timestamp.unwrap_or_else(Utc::now),
            /*echo_to_stdout*/ true,
        );
    }

    fn log(&self, level: &str, message: String, context: Option<serde_json::Value>) {
        if !self.enabled.load(Ordering::Relaxed) {
            return;
        }

        println!("[DESKTOP_BACKEND][{level}] {message}");

        self.enqueue(
            "desktop_backend".to_string(),
            level.to_string(),
            message,
            context,
            Utc::now(),
            /*echo_to_stdout*/ false,
        );
    }

    fn enqueue(
        &self,
        source: String,
        level: String,
        message: String,
        context: Option<serde_json::Value>,
        timestamp: chrono::DateTime<Utc>,
        echo_to_stdout: bool,
    ) {
        if !self.enabled.load(Ordering::Relaxed) {
            return;
        }
        if echo_to_stdout {
            println!("[{}][{}] {}", source.to_uppercase(), level, message);
        }
        let entry = RuntimeLogEntry {
            timestamp,
            level,
            message,
            context,
        };
        let mut pending = self.pending.lock().expect("runtime logger mutex poisoned");
        pending.push_back(PendingRuntimeLogEntry { source, entry });
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

        let mut grouped: Vec<(String, Vec<RuntimeLogEntry>)> = Vec::new();
        for pending_entry in &entries {
            if let Some((_, group_entries)) = grouped
                .iter_mut()
                .find(|(source, _)| source == &pending_entry.source)
            {
                group_entries.push(pending_entry.entry.clone());
            } else {
                grouped.push((
                    pending_entry.source.clone(),
                    vec![pending_entry.entry.clone()],
                ));
            }
        }

        for (source, source_entries) in grouped {
            let response = self
                .client
                .post(&self.endpoint)
                .json(&serde_json::json!({
                    "source": source,
                    "entries": source_entries,
                }))
                .send()
                .await?;

            if !response.status().is_success() {
                anyhow::bail!("backend returned status {}", response.status());
            }
        }

        let mut pending = self.pending.lock().expect("runtime logger mutex poisoned");
        let drain_count = entries.len().min(pending.len());
        pending.drain(..drain_count);
        Ok(())
    }
}
