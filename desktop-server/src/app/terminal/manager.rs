use std::{
    collections::HashMap,
    env,
    io::{Read, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
};

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use chrono::Utc;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde_json::json;
use tokio::sync::RwLock;
use tracing::{info, warn};
use uuid::Uuid;

type SharedMaster = Arc<Mutex<Box<dyn MasterPty + Send>>>;
type SharedWriter = Arc<Mutex<Box<dyn Write + Send>>>;
type SharedChild = Arc<Mutex<Box<dyn Child + Send + Sync>>>;

struct TerminalSessionHandle {
    master: SharedMaster,
    writer: SharedWriter,
    child: SharedChild,
}

pub struct TerminalManager {
    backend_base_url: String,
    device_id: String,
    sessions: Arc<RwLock<HashMap<Uuid, TerminalSessionHandle>>>,
    client: reqwest::Client,
}

impl TerminalManager {
    pub fn new(backend_base_url: String, device_id: String) -> Self {
        Self {
            backend_base_url: backend_base_url.trim_end_matches('/').to_string(),
            device_id,
            sessions: Arc::new(RwLock::new(HashMap::new())),
            client: reqwest::Client::new(),
        }
    }

    pub async fn create_terminal(
        &self,
        terminal_id: Uuid,
        shell: Option<String>,
        cwd: Option<String>,
        title: Option<String>,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<()> {
        let system = native_pty_system();
        let pair = system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let shell_path = resolve_shell(shell.as_deref());
        let mut builder = CommandBuilder::new(shell_path.clone());
        if let Some(dir) = cwd.as_deref().and_then(resolve_cwd) {
            builder.cwd(dir);
        }

        let child = pair.slave.spawn_command(builder)?;
        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let master = Arc::new(Mutex::new(pair.master));
        let writer = Arc::new(Mutex::new(writer));
        let child = Arc::new(Mutex::new(child));

        self.sessions.write().await.insert(
            terminal_id,
            TerminalSessionHandle {
                master: master.clone(),
                writer: writer.clone(),
                child: child.clone(),
            },
        );

        self.update_state(
            terminal_id,
            "active",
            title,
            Some(shell_path),
            cwd,
            Some(cols.into()),
            Some(rows.into()),
            None,
        )
        .await?;

        let client = self.client.clone();
        let backend_base_url = self.backend_base_url.clone();
        let device_id = self.device_id.clone();
        let runtime_handle = tokio::runtime::Handle::current();
        thread::spawn(move || {
            stream_terminal_output(
                reader,
                client,
                backend_base_url,
                device_id,
                terminal_id,
                runtime_handle,
            );
        });

        info!(terminal_id = %terminal_id, "terminal session created");
        Ok(())
    }

    pub async fn write_input(&self, terminal_id: Uuid, data_base64: &str) -> anyhow::Result<()> {
        let bytes = BASE64.decode(data_base64)?;
        let sessions = self.sessions.read().await;
        let handle = sessions
            .get(&terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;

        let mut writer = handle
            .writer
            .lock()
            .map_err(|_| anyhow::anyhow!("terminal writer poisoned"))?;
        writer.write_all(&bytes)?;
        writer.flush()?;
        Ok(())
    }

    pub async fn resize(&self, terminal_id: Uuid, cols: u16, rows: u16) -> anyhow::Result<()> {
        let sessions = self.sessions.read().await;
        let handle = sessions
            .get(&terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;

        let master = handle
            .master
            .lock()
            .map_err(|_| anyhow::anyhow!("terminal master poisoned"))?;
        master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        Ok(())
    }

    pub async fn close(&self, terminal_id: Uuid) -> anyhow::Result<()> {
        if let Some(handle) = self.sessions.write().await.remove(&terminal_id) {
            if let Ok(mut child) = handle.child.lock() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        self.update_state(terminal_id, "closed", None, None, None, None, None, None)
            .await?;
        Ok(())
    }

    pub async fn update_state(
        &self,
        terminal_id: Uuid,
        state: &str,
        title: Option<String>,
        shell: Option<String>,
        cwd: Option<String>,
        cols: Option<i32>,
        rows: Option<i32>,
        error_message: Option<String>,
    ) -> anyhow::Result<()> {
        let url = format!(
            "{}/api/v1/desktop/terminals/{}/state",
            self.backend_base_url, terminal_id
        );
        self.client
            .post(url)
            .json(&json!({
                "device_id": self.device_id,
                "state": state,
                "title": title,
                "shell": shell,
                "cwd": cwd,
                "cols": cols,
                "rows": rows,
                "error_message": error_message,
            }))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }
}

fn stream_terminal_output(
    mut reader: Box<dyn Read + Send>,
    client: reqwest::Client,
    backend_base_url: String,
    device_id: String,
    terminal_id: Uuid,
    runtime: tokio::runtime::Handle,
) {
    let mut buffer = [0_u8; 4096];

    loop {
        match reader.read(&mut buffer) {
            Ok(0) => {
                let _ = runtime.block_on(async {
                    let url = format!(
                        "{}/api/v1/desktop/terminals/{}/state",
                        backend_base_url, terminal_id
                    );
                    client
                        .post(url)
                        .json(&json!({
                            "device_id": device_id,
                            "state": "closed",
                        }))
                        .send()
                        .await?
                        .error_for_status()?;
                    anyhow::Ok(())
                });
                break;
            }
            Ok(read_len) => {
                let payload = BASE64.encode(&buffer[..read_len]);
                let result = runtime.block_on(async {
                    let url = format!(
                        "{}/api/v1/desktop/terminals/{}/output",
                        backend_base_url, terminal_id
                    );
                    client
                        .post(url)
                        .json(&json!({
                            "device_id": device_id,
                            "data_base64": payload,
                            "timestamp": Utc::now(),
                        }))
                        .send()
                        .await?
                        .error_for_status()?;
                    anyhow::Ok(())
                });
                if let Err(error) = result {
                    warn!(terminal_id = %terminal_id, error = %error, "terminal output upload failed");
                    break;
                }
            }
            Err(error) => {
                let _ = runtime.block_on(async {
                    let url = format!(
                        "{}/api/v1/desktop/terminals/{}/state",
                        backend_base_url, terminal_id
                    );
                    client
                        .post(url)
                        .json(&json!({
                            "device_id": device_id,
                            "state": "error",
                            "error_message": error.to_string(),
                        }))
                        .send()
                        .await?
                        .error_for_status()?;
                    anyhow::Ok(())
                });
                break;
            }
        }
    }
}

fn resolve_shell(requested: Option<&str>) -> String {
    if let Some(shell) = requested.filter(|value| !value.trim().is_empty() && *value != "default") {
        return shell.to_string();
    }

    #[cfg(target_os = "windows")]
    {
        if let Ok(shell) = env::var("COMSPEC") {
            if !shell.trim().is_empty() {
                return shell;
            }
        }
        return "powershell.exe".to_string();
    }

    #[cfg(target_os = "macos")]
    {
        if let Ok(shell) = env::var("SHELL") {
            if !shell.trim().is_empty() {
                return shell;
            }
        }
        return "/bin/zsh".to_string();
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Ok(shell) = env::var("SHELL") {
            if !shell.trim().is_empty() {
                return shell;
            }
        }
        return "/bin/bash".to_string();
    }
}

fn resolve_cwd(raw: &str) -> Option<PathBuf> {
    if raw == "~" {
        return env::var("HOME").ok().map(PathBuf::from);
    }
    Some(PathBuf::from(raw))
}
