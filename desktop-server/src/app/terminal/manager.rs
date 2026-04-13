use std::{
    collections::{HashMap, VecDeque},
    env,
    io::{Read, Write},
    path::PathBuf,
    sync::mpsc::{self, RecvTimeoutError},
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use chrono::{DateTime, Utc};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde_json::json;
use tokio::sync::{broadcast, RwLock};
use tracing::{info, warn};
use uuid::Uuid;

use crate::app::ai::config::{AiLaunchConfig, SIRIX_AGENT_RUNTIME_FILE_NAME};

type SharedMaster = Arc<Mutex<Box<dyn MasterPty + Send>>>;
type SharedWriter = Arc<Mutex<Box<dyn Write + Send>>>;
type SharedChild = Arc<Mutex<Box<dyn Child + Send + Sync>>>;
type SharedReplayBuffer = Arc<Mutex<TerminalReplayBuffer>>;

const TERMINAL_OUTPUT_FLUSH_INTERVAL: Duration = Duration::from_millis(12);
const TERMINAL_OUTPUT_MAX_BATCH_BYTES: usize = 16 * 1024;
const TERMINAL_OUTPUT_REPLAY_MAX_BYTES: usize = 1024 * 1024;

struct TerminalSessionHandle {
    master: SharedMaster,
    writer: SharedWriter,
    child: SharedChild,
    metadata: Arc<Mutex<TerminalSessionMetadata>>,
    replay_buffer: SharedReplayBuffer,
    remote_sync: bool,
}

#[derive(Debug, Clone)]
struct TerminalSessionMetadata {
    title: String,
    shell: String,
    cwd: String,
    state: String,
    cols: u16,
    rows: u16,
    created_at: DateTime<Utc>,
    closed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Default)]
struct TerminalReplayBuffer {
    bytes: VecDeque<u8>,
}

impl TerminalReplayBuffer {
    fn append(&mut self, chunk: &[u8]) {
        if chunk.is_empty() {
            return;
        }

        if chunk.len() >= TERMINAL_OUTPUT_REPLAY_MAX_BYTES {
            self.bytes.clear();
            self.bytes.extend(
                chunk[chunk.len() - TERMINAL_OUTPUT_REPLAY_MAX_BYTES..]
                    .iter()
                    .copied(),
            );
            return;
        }

        let overflow = self
            .bytes
            .len()
            .saturating_add(chunk.len())
            .saturating_sub(TERMINAL_OUTPUT_REPLAY_MAX_BYTES);
        for _ in 0..overflow {
            let _ = self.bytes.pop_front();
        }

        self.bytes.extend(chunk.iter().copied());
    }

    fn snapshot(&self) -> Vec<u8> {
        self.bytes.iter().copied().collect()
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct LocalTerminalSnapshot {
    pub terminal_id: Uuid,
    pub device_id: String,
    pub title: String,
    pub shell: String,
    pub cwd: String,
    pub state: String,
    pub cols: i32,
    pub rows: i32,
    pub created_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
}

pub struct TerminalManager {
    backend_base_url: String,
    device_id: String,
    local_events: broadcast::Sender<String>,
    sessions: Arc<RwLock<HashMap<Uuid, TerminalSessionHandle>>>,
    client: reqwest::Client,
    sirix_home: PathBuf,
}

impl TerminalManager {
    pub fn new(
        backend_base_url: String,
        device_id: String,
        local_events: broadcast::Sender<String>,
        sirix_home: PathBuf,
    ) -> Self {
        Self {
            backend_base_url: backend_base_url.trim_end_matches('/').to_string(),
            device_id,
            local_events,
            sessions: Arc::new(RwLock::new(HashMap::new())),
            client: reqwest::Client::new(),
            sirix_home,
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
        let shell_path = resolve_shell(shell.as_deref());
        let cwd_display = cwd.clone().unwrap_or_else(|| "~".to_string());
        let title = title.clone().unwrap_or_else(|| "Terminal".to_string());
        let mut builder = CommandBuilder::new(shell_path.clone());
        if let Some(dir) = cwd.as_deref().and_then(resolve_cwd) {
            builder.cwd(dir);
        }
        self.apply_sirix_env(&mut builder, Some(terminal_id))?;

        self.create_process_terminal(
            terminal_id,
            builder,
            title.clone(),
            shell_path.clone(),
            cwd_display.clone(),
            cols,
            rows,
            true,
            Some(title),
            Some(shell_path),
            Some(cwd_display),
        )
        .await?;
        info!(terminal_id = %terminal_id, "terminal session created");
        Ok(())
    }

    pub async fn create_codex_terminal(
        &self,
        terminal_id: Uuid,
        launch: AiLaunchConfig,
        ai_session_id: Uuid,
        local_ws_port: u16,
        cols: u16,
        rows: u16,
        remote_sync: bool,
    ) -> anyhow::Result<()> {
        let codex_executable = resolve_codex_executable()?;
        let mut builder = CommandBuilder::new(codex_executable.clone());
        if !launch.provider.api_key.trim().is_empty()
            && !launch.provider.api_key_env.trim().is_empty()
        {
            builder.env(&launch.provider.api_key_env, &launch.provider.api_key);
        }
        self.apply_sirix_env(&mut builder, None)?;
        builder.env("CODEX_HOME", &launch.codex_home);
        builder.env("SIRIX_AI_SESSION_ID", ai_session_id.to_string());
        builder.env(
            "SIRIX_LOCAL_API_BASE",
            format!("http://127.0.0.1:{local_ws_port}"),
        );
        builder.env(
            "SIRIX_AGENT_RUNTIME_PATH",
            launch
                .codex_home
                .join(SIRIX_AGENT_RUNTIME_FILE_NAME)
                .display()
                .to_string(),
        );
        builder.cwd(&launch.workspace_root);

        self.create_process_terminal(
            terminal_id,
            builder,
            format!("Sirix AI · {}", launch.agent.name),
            "sirix-runtime".to_string(),
            launch.workspace_root.display().to_string(),
            cols,
            rows,
            remote_sync,
            Some(format!("Sirix AI · {}", launch.agent.name)),
            Some("codex".to_string()),
            Some(launch.workspace_root.display().to_string()),
        )
        .await
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
        if let Ok(mut metadata) = handle.metadata.lock() {
            metadata.cols = cols;
            metadata.rows = rows;
        }
        Ok(())
    }

    pub async fn close(&self, terminal_id: Uuid) -> anyhow::Result<()> {
        let mut remote_sync = false;
        if let Some(handle) = self.sessions.write().await.remove(&terminal_id) {
            remote_sync = handle.remote_sync;
            if let Ok(mut metadata) = handle.metadata.lock() {
                metadata.state = "closed".to_string();
                metadata.closed_at = Some(Utc::now());
            }
            if let Ok(mut child) = handle.child.lock() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        if remote_sync {
            self.update_state(terminal_id, "closed", None, None, None, None, None, None)
                .await?;
        }
        self.publish_local_terminal_event("terminal.closed", json!({ "terminal_id": terminal_id }));
        Ok(())
    }

    pub async fn get_snapshot(&self, terminal_id: Uuid) -> Option<LocalTerminalSnapshot> {
        let sessions = self.sessions.read().await;
        let handle = sessions.get(&terminal_id)?;
        let metadata = handle.metadata.lock().ok()?.clone();
        Some(LocalTerminalSnapshot {
            terminal_id,
            device_id: self.device_id.clone(),
            title: metadata.title,
            shell: metadata.shell,
            cwd: metadata.cwd,
            state: metadata.state,
            cols: i32::from(metadata.cols),
            rows: i32::from(metadata.rows),
            created_at: metadata.created_at,
            closed_at: metadata.closed_at,
        })
    }

    pub async fn list_snapshots(&self) -> Vec<LocalTerminalSnapshot> {
        let sessions = self.sessions.read().await;
        let mut items = Vec::with_capacity(sessions.len());
        for (terminal_id, handle) in sessions.iter() {
            if let Ok(metadata) = handle.metadata.lock() {
                let metadata = metadata.clone();
                if metadata.state == "closed" {
                    continue;
                }
                items.push(LocalTerminalSnapshot {
                    terminal_id: *terminal_id,
                    device_id: self.device_id.clone(),
                    title: metadata.title,
                    shell: metadata.shell,
                    cwd: metadata.cwd,
                    state: metadata.state,
                    cols: i32::from(metadata.cols),
                    rows: i32::from(metadata.rows),
                    created_at: metadata.created_at,
                    closed_at: metadata.closed_at,
                });
            }
        }
        items.sort_by(|left, right| left.created_at.cmp(&right.created_at));
        items
    }

    pub async fn get_output_snapshot_base64(&self, terminal_id: Uuid) -> Option<String> {
        let sessions = self.sessions.read().await;
        let handle = sessions.get(&terminal_id)?;
        let replay = handle.replay_buffer.lock().ok()?;
        let snapshot = replay.snapshot();
        if snapshot.is_empty() {
            return None;
        }
        Some(BASE64.encode(snapshot))
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
        if !self.is_remote_sync(terminal_id).await {
            return Ok(());
        }
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

    pub async fn publish_local_terminal_ready(&self, terminal_id: Uuid) {
        if let Some(snapshot) = self.get_snapshot(terminal_id).await {
            self.publish_local_terminal_event("terminal.ready", json!(snapshot));
        }
    }

    pub fn publish_local_terminal_event(&self, event_type: &str, payload: serde_json::Value) {
        let _ = self.local_events.send(
            json!({
                "type": event_type,
                "payload": payload,
            })
            .to_string(),
        );
    }

    fn apply_sirix_env(
        &self,
        builder: &mut CommandBuilder,
        terminal_id: Option<Uuid>,
    ) -> anyhow::Result<()> {
        let path = env::var("PATH").unwrap_or_default();
        let sirix_bin = self.sirix_home.join("bin");
        let separator = if cfg!(windows) { ';' } else { ':' };
        let augmented_path = if path.trim().is_empty() {
            sirix_bin.display().to_string()
        } else {
            format!("{}{}{}", sirix_bin.display(), separator, path)
        };
        let runtime_executable = resolve_codex_executable()?;
        builder.env("PATH", &augmented_path);
        builder.env("SIRIX_HOME", &self.sirix_home);
        builder.env("SIRIX_CODEX_EXECUTABLE", runtime_executable);
        if let Some(terminal_id) = terminal_id {
            builder.env("SIRIX_TERMINAL_SESSION_ID", terminal_id.to_string());
        }
        Ok(())
    }

    async fn create_process_terminal(
        &self,
        terminal_id: Uuid,
        builder: CommandBuilder,
        title: String,
        shell: String,
        cwd: String,
        cols: u16,
        rows: u16,
        remote_sync: bool,
        remote_title: Option<String>,
        remote_shell: Option<String>,
        remote_cwd: Option<String>,
    ) -> anyhow::Result<()> {
        let system = native_pty_system();
        let pair = system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let child = pair.slave.spawn_command(builder)?;
        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let master = Arc::new(Mutex::new(pair.master));
        let writer = Arc::new(Mutex::new(writer));
        let child = Arc::new(Mutex::new(child));
        let metadata = Arc::new(Mutex::new(TerminalSessionMetadata {
            title: title.clone(),
            shell: shell.clone(),
            cwd: cwd.clone(),
            state: "active".to_string(),
            cols,
            rows,
            created_at: Utc::now(),
            closed_at: None,
        }));
        let replay_buffer = Arc::new(Mutex::new(TerminalReplayBuffer::default()));

        self.sessions.write().await.insert(
            terminal_id,
            TerminalSessionHandle {
                master: master.clone(),
                writer: writer.clone(),
                child: child.clone(),
                metadata: metadata.clone(),
                replay_buffer: replay_buffer.clone(),
                remote_sync,
            },
        );

        self.update_state(
            terminal_id,
            "active",
            remote_title.or_else(|| Some(title.clone())),
            remote_shell.or_else(|| Some(shell.clone())),
            remote_cwd.or_else(|| Some(cwd.clone())),
            Some(cols.into()),
            Some(rows.into()),
            None,
        )
        .await?;

        let client = self.client.clone();
        let backend_base_url = self.backend_base_url.clone();
        let device_id = self.device_id.clone();
        let local_events = self.local_events.clone();
        let runtime_handle = tokio::runtime::Handle::current();
        thread::spawn(move || {
            stream_terminal_output(
                reader,
                client,
                backend_base_url,
                device_id,
                local_events,
                terminal_id,
                metadata,
                replay_buffer,
                runtime_handle,
                remote_sync,
            );
        });

        self.publish_local_terminal_ready(terminal_id).await;
        Ok(())
    }

    async fn is_remote_sync(&self, terminal_id: Uuid) -> bool {
        self.sessions
            .read()
            .await
            .get(&terminal_id)
            .map(|handle| handle.remote_sync)
            .unwrap_or(false)
    }
}

fn stream_terminal_output(
    mut reader: Box<dyn Read + Send>,
    client: reqwest::Client,
    backend_base_url: String,
    device_id: String,
    local_events: broadcast::Sender<String>,
    terminal_id: Uuid,
    metadata: Arc<Mutex<TerminalSessionMetadata>>,
    replay_buffer: SharedReplayBuffer,
    runtime: tokio::runtime::Handle,
    remote_sync: bool,
) {
    let (tx, rx) = mpsc::sync_channel::<std::io::Result<Option<Vec<u8>>>>(32);

    thread::spawn(move || {
        let mut buffer = [0_u8; 4096];
        loop {
            let message = match reader.read(&mut buffer) {
                Ok(0) => Ok(None),
                Ok(read_len) => Ok(Some(buffer[..read_len].to_vec())),
                Err(error) => Err(error),
            };

            let should_stop = matches!(message, Ok(None) | Err(_));
            if tx.send(message).is_err() || should_stop {
                break;
            }
        }
    });

    let mut pending = Vec::with_capacity(TERMINAL_OUTPUT_MAX_BATCH_BYTES);
    loop {
        match rx.recv_timeout(TERMINAL_OUTPUT_FLUSH_INTERVAL) {
            Ok(Ok(Some(chunk))) => {
                pending.extend_from_slice(&chunk);
                if pending.len() >= TERMINAL_OUTPUT_MAX_BATCH_BYTES {
                    if let Err(error) = flush_terminal_output(
                        &client,
                        &backend_base_url,
                        &device_id,
                        &local_events,
                        terminal_id,
                        &replay_buffer,
                        &mut pending,
                        &runtime,
                        remote_sync,
                    ) {
                        warn!(terminal_id = %terminal_id, error = %error, "terminal output upload failed");
                        if remote_sync {
                            let _ = update_terminal_remote_state(
                                &client,
                                &backend_base_url,
                                &device_id,
                                terminal_id,
                                "error",
                                Some(error.to_string()),
                                &runtime,
                            );
                        }
                        break;
                    }
                }
            }
            Ok(Ok(None)) => {
                if let Err(error) = flush_terminal_output(
                    &client,
                    &backend_base_url,
                    &device_id,
                    &local_events,
                    terminal_id,
                    &replay_buffer,
                    &mut pending,
                    &runtime,
                    remote_sync,
                ) {
                    warn!(terminal_id = %terminal_id, error = %error, "terminal output upload failed");
                }
                if let Ok(mut metadata) = metadata.lock() {
                    metadata.state = "closed".to_string();
                    metadata.closed_at = Some(Utc::now());
                }
                if remote_sync {
                    let _ = update_terminal_remote_state(
                        &client,
                        &backend_base_url,
                        &device_id,
                        terminal_id,
                        "closed",
                        None,
                        &runtime,
                    );
                }
                let _ = local_events.send(
                    json!({
                        "type": "terminal.closed",
                        "payload": {
                            "terminal_id": terminal_id,
                        }
                    })
                    .to_string(),
                );
                break;
            }
            Ok(Err(error)) => {
                let _ = flush_terminal_output(
                    &client,
                    &backend_base_url,
                    &device_id,
                    &local_events,
                    terminal_id,
                    &replay_buffer,
                    &mut pending,
                    &runtime,
                    remote_sync,
                );
                if let Ok(mut metadata) = metadata.lock() {
                    metadata.state = "error".to_string();
                }
                if remote_sync {
                    let _ = update_terminal_remote_state(
                        &client,
                        &backend_base_url,
                        &device_id,
                        terminal_id,
                        "error",
                        Some(error.to_string()),
                        &runtime,
                    );
                }
                let _ = local_events.send(
                    json!({
                        "type": "terminal.error",
                        "payload": {
                            "terminal_id": terminal_id,
                            "error_message": error.to_string(),
                        }
                    })
                    .to_string(),
                );
                break;
            }
            Err(RecvTimeoutError::Timeout) => {
                if let Err(error) = flush_terminal_output(
                    &client,
                    &backend_base_url,
                    &device_id,
                    &local_events,
                    terminal_id,
                    &replay_buffer,
                    &mut pending,
                    &runtime,
                    remote_sync,
                ) {
                    warn!(terminal_id = %terminal_id, error = %error, "terminal output upload failed");
                    if remote_sync {
                        let _ = update_terminal_remote_state(
                            &client,
                            &backend_base_url,
                            &device_id,
                            terminal_id,
                            "error",
                            Some(error.to_string()),
                            &runtime,
                        );
                    }
                    break;
                }
            }
            Err(RecvTimeoutError::Disconnected) => {
                let _ = flush_terminal_output(
                    &client,
                    &backend_base_url,
                    &device_id,
                    &local_events,
                    terminal_id,
                    &replay_buffer,
                    &mut pending,
                    &runtime,
                    remote_sync,
                );
                break;
            }
        }
    }
}

fn flush_terminal_output(
    client: &reqwest::Client,
    backend_base_url: &str,
    device_id: &str,
    local_events: &broadcast::Sender<String>,
    terminal_id: Uuid,
    replay_buffer: &SharedReplayBuffer,
    pending: &mut Vec<u8>,
    runtime: &tokio::runtime::Handle,
    remote_sync: bool,
) -> anyhow::Result<()> {
    if pending.is_empty() {
        return Ok(());
    }

    let snapshot = pending.clone();
    if let Ok(mut replay) = replay_buffer.lock() {
        replay.append(&snapshot);
    }

    let payload = BASE64.encode(&snapshot);
    pending.clear();
    let _ = local_events.send(
        json!({
            "type": "terminal.output",
            "payload": {
                "terminal_id": terminal_id,
                "data_base64": payload.clone(),
            }
        })
        .to_string(),
    );

    if !remote_sync {
        return Ok(());
    }

    runtime.block_on(async {
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
    })
}

fn update_terminal_remote_state(
    client: &reqwest::Client,
    backend_base_url: &str,
    device_id: &str,
    terminal_id: Uuid,
    state: &str,
    error_message: Option<String>,
    runtime: &tokio::runtime::Handle,
) -> anyhow::Result<()> {
    runtime.block_on(async {
        let url = format!(
            "{}/api/v1/desktop/terminals/{}/state",
            backend_base_url, terminal_id
        );
        client
            .post(url)
            .json(&json!({
                "device_id": device_id,
                "state": state,
                "error_message": error_message,
            }))
            .send()
            .await?
            .error_for_status()?;
        anyhow::Ok(())
    })
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

pub(crate) fn resolve_codex_executable() -> anyhow::Result<String> {
    if let Ok(codex) = env::var("SIRIX_CODEX_EXECUTABLE") {
        if !codex.trim().is_empty() {
            return Ok(codex);
        }
    }

    if let Ok(current_exe) = env::current_exe() {
        if let Some(parent) = current_exe.parent() {
            let runtime_name = if cfg!(windows) {
                "sirix-runtime.exe"
            } else {
                "sirix-runtime"
            };
            let runtime = parent.join(runtime_name);
            if runtime.is_file() {
                return Ok(runtime.display().to_string());
            }
        }
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for profile in ["debug", "release"] {
        let runtime = manifest_dir
            .join("..")
            .join("third_party")
            .join("codex-rs")
            .join("target")
            .join(profile)
            .join(if cfg!(windows) {
                "sirix-runtime.exe"
            } else {
                "sirix-runtime"
            });
        if runtime.is_file() {
            return Ok(runtime.display().to_string());
        }
    }

    let path_entry = if cfg!(windows) {
        "sirix-runtime.exe"
    } else {
        "sirix-runtime"
    };
    if executable_in_path(path_entry) {
        return Ok(path_entry.to_string());
    }

    anyhow::bail!(
        "Sirix AI runtime executable not found. Expected `sirix-runtime` next to the app, in `third_party/codex-rs/target/{{debug,release}}`, or on PATH."
    )
}

fn resolve_cwd(raw: &str) -> Option<PathBuf> {
    if raw == "~" {
        return env::var("HOME").ok().map(PathBuf::from);
    }
    Some(PathBuf::from(raw))
}

fn executable_in_path(name: &str) -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };
    env::split_paths(&path).any(|directory| directory.join(name).is_file())
}
