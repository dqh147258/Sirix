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
use tokio::sync::{broadcast, mpsc::UnboundedSender, RwLock};
use tracing::{info, warn};
use uuid::Uuid;

use crate::app::ai::config::{
    AiLaunchConfig, SIRIX_CONFIG_OVERRIDES_PATH_ENV, SIRIX_EXEC_POLICY_PATH_ENV,
};

type SharedMaster = Arc<Mutex<Box<dyn MasterPty + Send>>>;
type SharedWriter = Arc<Mutex<Box<dyn Write + Send>>>;
type SharedChild = Arc<Mutex<Box<dyn Child + Send + Sync>>>;
type SharedReplayBuffer = Arc<Mutex<TerminalReplayBuffer>>;
type SharedHostedControlSender = Arc<Mutex<Option<UnboundedSender<HostedTerminalCommand>>>>;

const TERMINAL_OUTPUT_FLUSH_INTERVAL: Duration = Duration::from_millis(12);
const TERMINAL_OUTPUT_MAX_BATCH_BYTES: usize = 16 * 1024;
const TERMINAL_OUTPUT_REPLAY_MAX_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalSessionSource {
    LocalPty,
    Hosted,
}

impl TerminalSessionSource {
    pub fn as_api_str(self) -> &'static str {
        match self {
            Self::LocalPty => "local_pty",
            Self::Hosted => "hosted",
        }
    }

    pub fn supports_ai_current_terminal_reuse(self) -> bool {
        matches!(self, Self::LocalPty)
    }
}

struct TerminalSessionHandle {
    endpoint: TerminalSessionEndpoint,
    metadata: Arc<Mutex<TerminalSessionMetadata>>,
    replay_buffer: SharedReplayBuffer,
    remote_sync: bool,
}

enum TerminalSessionEndpoint {
    LocalPty {
        master: SharedMaster,
        writer: SharedWriter,
        child: SharedChild,
    },
    Hosted {
        host_token: String,
        control_sender: SharedHostedControlSender,
    },
}

impl TerminalSessionEndpoint {
    fn source(&self) -> TerminalSessionSource {
        match self {
            Self::LocalPty { .. } => TerminalSessionSource::LocalPty,
            Self::Hosted { .. } => TerminalSessionSource::Hosted,
        }
    }
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

enum TerminalCloseReason {
    Closed,
    Error(String),
}

#[derive(Clone)]
struct TerminalOutputContext {
    client: reqwest::Client,
    backend_base_url: String,
    device_id: String,
    local_events: broadcast::Sender<String>,
    terminal_id: Uuid,
    replay_buffer: SharedReplayBuffer,
    remote_sync: bool,
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
    pub source: String,
    pub shell: String,
    pub cwd: String,
    pub state: String,
    pub cols: i32,
    pub rows: i32,
    pub created_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct HostedTerminalSession {
    pub terminal_id: Uuid,
    pub host_token: String,
    pub remote_sync: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "type")]
pub enum HostedTerminalCommand {
    #[serde(rename = "terminal.host.input")]
    Input {
        terminal_id: Uuid,
        data_base64: String,
    },
    #[serde(rename = "terminal.host.resize")]
    Resize {
        terminal_id: Uuid,
        cols: u16,
        rows: u16,
    },
    #[serde(rename = "terminal.host.close")]
    Close { terminal_id: Uuid },
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
        config_overrides_path: PathBuf,
        agent_runtime_path: PathBuf,
        exec_policy_path: PathBuf,
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
        builder.env(SIRIX_CONFIG_OVERRIDES_PATH_ENV, config_overrides_path);
        builder.env("SIRIX_AGENT_RUNTIME_PATH", agent_runtime_path);
        builder.env(SIRIX_EXEC_POLICY_PATH_ENV, exec_policy_path);
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

        match &handle.endpoint {
            TerminalSessionEndpoint::LocalPty { writer, .. } => {
                let mut writer = writer
                    .lock()
                    .map_err(|_| anyhow::anyhow!("terminal writer poisoned"))?;
                writer.write_all(&bytes)?;
            }
            TerminalSessionEndpoint::Hosted { control_sender, .. } => {
                let payload = HostedTerminalCommand::Input {
                    terminal_id,
                    data_base64: data_base64.to_string(),
                };
                let sender = control_sender
                    .lock()
                    .map_err(|_| anyhow::anyhow!("hosted terminal control sender poisoned"))?
                    .clone()
                    .ok_or_else(|| anyhow::anyhow!("hosted terminal is not connected"))?;
                sender
                    .send(payload)
                    .map_err(|_| anyhow::anyhow!("failed to deliver hosted terminal input"))?;
            }
        }
        Ok(())
    }

    pub async fn resize(&self, terminal_id: Uuid, cols: u16, rows: u16) -> anyhow::Result<()> {
        let sessions = self.sessions.read().await;
        let handle = sessions
            .get(&terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;

        match &handle.endpoint {
            TerminalSessionEndpoint::LocalPty { master, .. } => {
                let master = master
                    .lock()
                    .map_err(|_| anyhow::anyhow!("terminal master poisoned"))?;
                master.resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })?;
            }
            TerminalSessionEndpoint::Hosted { control_sender, .. } => {
                let payload = HostedTerminalCommand::Resize {
                    terminal_id,
                    cols,
                    rows,
                };
                let sender = control_sender
                    .lock()
                    .map_err(|_| anyhow::anyhow!("hosted terminal control sender poisoned"))?
                    .clone()
                    .ok_or_else(|| anyhow::anyhow!("hosted terminal is not connected"))?;
                sender
                    .send(payload)
                    .map_err(|_| anyhow::anyhow!("failed to deliver hosted terminal resize"))?;
            }
        }
        if let Ok(mut metadata) = handle.metadata.lock() {
            metadata.cols = cols;
            metadata.rows = rows;
        }
        Ok(())
    }

    pub async fn close(&self, terminal_id: Uuid) -> anyhow::Result<()> {
        self.close_session(terminal_id, TerminalCloseReason::Closed, true)
            .await
    }

    pub async fn create_hosted_terminal(
        &self,
        terminal_id: Uuid,
        shell: String,
        cwd: String,
        title: String,
        cols: u16,
        rows: u16,
        remote_sync: bool,
    ) -> anyhow::Result<HostedTerminalSession> {
        let host_token = Uuid::new_v4().to_string();
        let metadata = Arc::new(Mutex::new(TerminalSessionMetadata {
            title: title.clone(),
            shell: shell.clone(),
            cwd: cwd.clone(),
            state: "opening".to_string(),
            cols,
            rows,
            created_at: Utc::now(),
            closed_at: None,
        }));
        let replay_buffer = Arc::new(Mutex::new(TerminalReplayBuffer::default()));
        self.sessions.write().await.insert(
            terminal_id,
            TerminalSessionHandle {
                endpoint: TerminalSessionEndpoint::Hosted {
                    host_token: host_token.clone(),
                    control_sender: Arc::new(Mutex::new(None)),
                },
                metadata,
                replay_buffer,
                remote_sync,
            },
        );

        self.update_state(
            terminal_id,
            "opening",
            Some(title),
            Some(shell),
            Some(cwd),
            Some(cols.into()),
            Some(rows.into()),
            None,
        )
        .await?;
        self.publish_local_terminal_ready(terminal_id).await;

        Ok(HostedTerminalSession {
            terminal_id,
            host_token,
            remote_sync,
        })
    }

    pub async fn register_hosted_terminal(
        &self,
        terminal_id: Uuid,
        host_token: &str,
        sender: UnboundedSender<HostedTerminalCommand>,
    ) -> anyhow::Result<()> {
        let sessions = self.sessions.read().await;
        let handle = sessions
            .get(&terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
        let TerminalSessionEndpoint::Hosted {
            host_token: expected_token,
            control_sender,
        } = &handle.endpoint
        else {
            anyhow::bail!("terminal session is not hosted");
        };
        if expected_token != host_token.trim() {
            anyhow::bail!("invalid hosted terminal registration token");
        }

        {
            let mut guard = control_sender
                .lock()
                .map_err(|_| anyhow::anyhow!("hosted terminal control sender poisoned"))?;
            if guard.is_some() {
                anyhow::bail!("hosted terminal already has an active host connection");
            }
            *guard = Some(sender);
        }
        if let Ok(mut metadata) = handle.metadata.lock() {
            metadata.state = "active".to_string();
        }
        drop(sessions);

        self.update_state(terminal_id, "active", None, None, None, None, None, None)
            .await?;
        self.publish_local_terminal_ready(terminal_id).await;
        Ok(())
    }

    pub async fn ingest_hosted_output(
        &self,
        terminal_id: Uuid,
        data_base64: &str,
    ) -> anyhow::Result<()> {
        let bytes = BASE64.decode(data_base64)?;
        self.push_terminal_output(terminal_id, &bytes).await?;
        Ok(())
    }

    pub async fn update_hosted_terminal_size(
        &self,
        terminal_id: Uuid,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<()> {
        let sessions = self.sessions.read().await;
        let handle = sessions
            .get(&terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
        let TerminalSessionEndpoint::Hosted { .. } = &handle.endpoint else {
            anyhow::bail!("terminal session is not hosted");
        };
        if let Ok(mut metadata) = handle.metadata.lock() {
            metadata.cols = cols;
            metadata.rows = rows;
        }
        drop(sessions);

        self.update_state(
            terminal_id,
            "active",
            None,
            None,
            None,
            Some(cols.into()),
            Some(rows.into()),
            None,
        )
        .await
    }

    pub async fn complete_hosted_terminal(
        &self,
        terminal_id: Uuid,
        error_message: Option<String>,
    ) -> anyhow::Result<()> {
        let reason = if let Some(message) = error_message {
            TerminalCloseReason::Error(message)
        } else {
            TerminalCloseReason::Closed
        };
        self.close_session(terminal_id, reason, false).await
    }

    pub async fn hosted_terminal_disconnected(&self, terminal_id: Uuid) -> anyhow::Result<()> {
        self.close_session(
            terminal_id,
            TerminalCloseReason::Error("hosted terminal connection dropped".to_string()),
            false,
        )
        .await
    }

    pub async fn get_snapshot(&self, terminal_id: Uuid) -> Option<LocalTerminalSnapshot> {
        let sessions = self.sessions.read().await;
        let handle = sessions.get(&terminal_id)?;
        let metadata = handle.metadata.lock().ok()?.clone();
        Some(LocalTerminalSnapshot {
            terminal_id,
            device_id: self.device_id.clone(),
            title: metadata.title,
            source: handle.endpoint.source().as_api_str().to_string(),
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
                    source: handle.endpoint.source().as_api_str().to_string(),
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
            builder.env(
                "SIRIX_TERMINAL_KIND",
                TerminalSessionSource::LocalPty.as_api_str(),
            );
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
                endpoint: TerminalSessionEndpoint::LocalPty {
                    master: master.clone(),
                    writer: writer.clone(),
                    child: child.clone(),
                },
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

        let output_context = TerminalOutputContext {
            client: self.client.clone(),
            backend_base_url: self.backend_base_url.clone(),
            device_id: self.device_id.clone(),
            local_events: self.local_events.clone(),
            terminal_id,
            replay_buffer: replay_buffer.clone(),
            remote_sync,
        };
        let runtime_handle = tokio::runtime::Handle::current();
        thread::spawn(move || {
            stream_terminal_output(reader, output_context, metadata, runtime_handle);
        });

        self.publish_local_terminal_ready(terminal_id).await;
        Ok(())
    }

    async fn close_session(
        &self,
        terminal_id: Uuid,
        reason: TerminalCloseReason,
        notify_host: bool,
    ) -> anyhow::Result<()> {
        let Some(handle) = self.sessions.write().await.remove(&terminal_id) else {
            return Ok(());
        };
        let event_type = match &reason {
            TerminalCloseReason::Closed => "terminal.closed",
            TerminalCloseReason::Error(_) => "terminal.error",
        };
        let error_message = match &reason {
            TerminalCloseReason::Closed => None,
            TerminalCloseReason::Error(message) => Some(message.clone()),
        };

        if let Ok(mut metadata) = handle.metadata.lock() {
            metadata.state = if error_message.is_some() {
                "error".to_string()
            } else {
                "closed".to_string()
            };
            metadata.closed_at = Some(Utc::now());
        }

        match handle.endpoint {
            TerminalSessionEndpoint::LocalPty { child, .. } => {
                if let Ok(mut child) = child.lock() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
            }
            TerminalSessionEndpoint::Hosted { control_sender, .. } => {
                if notify_host {
                    if let Ok(guard) = control_sender.lock() {
                        if let Some(sender) = guard.as_ref() {
                            let _ = sender.send(HostedTerminalCommand::Close { terminal_id });
                        }
                    }
                }
            }
        }

        self.update_state(
            terminal_id,
            if error_message.is_some() {
                "error"
            } else {
                "closed"
            },
            None,
            None,
            None,
            None,
            None,
            error_message.clone(),
        )
        .await?;
        self.publish_local_terminal_event(
            event_type,
            match error_message {
                Some(message) => json!({
                    "terminal_id": terminal_id,
                    "error_message": message,
                }),
                None => json!({
                    "terminal_id": terminal_id,
                }),
            },
        );
        Ok(())
    }

    async fn output_context(&self, terminal_id: Uuid) -> Option<TerminalOutputContext> {
        let sessions = self.sessions.read().await;
        let handle = sessions.get(&terminal_id)?;
        Some(TerminalOutputContext {
            client: self.client.clone(),
            backend_base_url: self.backend_base_url.clone(),
            device_id: self.device_id.clone(),
            local_events: self.local_events.clone(),
            terminal_id,
            replay_buffer: handle.replay_buffer.clone(),
            remote_sync: handle.remote_sync,
        })
    }

    async fn push_terminal_output(&self, terminal_id: Uuid, chunk: &[u8]) -> anyhow::Result<()> {
        if chunk.is_empty() {
            return Ok(());
        }
        let Some(context) = self.output_context(terminal_id).await else {
            anyhow::bail!("terminal session not found");
        };
        push_terminal_output_chunk(&context, chunk).await
    }

    async fn is_remote_sync(&self, terminal_id: Uuid) -> bool {
        self.sessions
            .read()
            .await
            .get(&terminal_id)
            .map(|handle| handle.remote_sync)
            .unwrap_or(false)
    }

    pub async fn session_source(&self, terminal_id: Uuid) -> Option<TerminalSessionSource> {
        self.sessions
            .read()
            .await
            .get(&terminal_id)
            .map(|handle| handle.endpoint.source())
    }
}

fn stream_terminal_output(
    mut reader: Box<dyn Read + Send>,
    context: TerminalOutputContext,
    metadata: Arc<Mutex<TerminalSessionMetadata>>,
    runtime: tokio::runtime::Handle,
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
                    if let Err(error) = flush_terminal_output(&context, &mut pending, &runtime) {
                        warn!(terminal_id = %context.terminal_id, error = %error, "terminal output upload failed");
                        if context.remote_sync {
                            let _ = update_terminal_remote_state(
                                &context.client,
                                &context.backend_base_url,
                                &context.device_id,
                                context.terminal_id,
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
                if let Err(error) = flush_terminal_output(&context, &mut pending, &runtime) {
                    warn!(terminal_id = %context.terminal_id, error = %error, "terminal output upload failed");
                }
                if let Ok(mut metadata) = metadata.lock() {
                    metadata.state = "closed".to_string();
                    metadata.closed_at = Some(Utc::now());
                }
                if context.remote_sync {
                    let _ = update_terminal_remote_state(
                        &context.client,
                        &context.backend_base_url,
                        &context.device_id,
                        context.terminal_id,
                        "closed",
                        None,
                        &runtime,
                    );
                }
                let _ = context.local_events.send(
                    json!({
                        "type": "terminal.closed",
                        "payload": {
                            "terminal_id": context.terminal_id,
                        }
                    })
                    .to_string(),
                );
                break;
            }
            Ok(Err(error)) => {
                let _ = flush_terminal_output(&context, &mut pending, &runtime);
                if let Ok(mut metadata) = metadata.lock() {
                    metadata.state = "error".to_string();
                }
                if context.remote_sync {
                    let _ = update_terminal_remote_state(
                        &context.client,
                        &context.backend_base_url,
                        &context.device_id,
                        context.terminal_id,
                        "error",
                        Some(error.to_string()),
                        &runtime,
                    );
                }
                let _ = context.local_events.send(
                    json!({
                        "type": "terminal.error",
                        "payload": {
                            "terminal_id": context.terminal_id,
                            "error_message": error.to_string(),
                        }
                    })
                    .to_string(),
                );
                break;
            }
            Err(RecvTimeoutError::Timeout) => {
                if let Err(error) = flush_terminal_output(&context, &mut pending, &runtime) {
                    warn!(terminal_id = %context.terminal_id, error = %error, "terminal output upload failed");
                    if context.remote_sync {
                        let _ = update_terminal_remote_state(
                            &context.client,
                            &context.backend_base_url,
                            &context.device_id,
                            context.terminal_id,
                            "error",
                            Some(error.to_string()),
                            &runtime,
                        );
                    }
                    break;
                }
            }
            Err(RecvTimeoutError::Disconnected) => {
                let _ = flush_terminal_output(&context, &mut pending, &runtime);
                break;
            }
        }
    }
}

fn flush_terminal_output(
    context: &TerminalOutputContext,
    pending: &mut Vec<u8>,
    runtime: &tokio::runtime::Handle,
) -> anyhow::Result<()> {
    if pending.is_empty() {
        return Ok(());
    }

    let snapshot = pending.clone();
    if let Ok(mut replay) = context.replay_buffer.lock() {
        replay.append(&snapshot);
    }

    let payload = BASE64.encode(&snapshot);
    pending.clear();
    let _ = context.local_events.send(
        json!({
            "type": "terminal.output",
            "payload": {
                "terminal_id": context.terminal_id,
                "data_base64": payload.clone(),
            }
        })
        .to_string(),
    );

    if !context.remote_sync {
        return Ok(());
    }

    runtime.block_on(async {
        let url = format!(
            "{}/api/v1/desktop/terminals/{}/output",
            context.backend_base_url, context.terminal_id
        );
        context
            .client
            .post(url)
            .json(&json!({
                "device_id": context.device_id,
                "data_base64": payload,
                "timestamp": Utc::now(),
            }))
            .send()
            .await?
            .error_for_status()?;
        anyhow::Ok(())
    })
}

async fn push_terminal_output_chunk(
    context: &TerminalOutputContext,
    chunk: &[u8],
) -> anyhow::Result<()> {
    if let Ok(mut replay) = context.replay_buffer.lock() {
        replay.append(chunk);
    }

    let payload = BASE64.encode(chunk);
    let _ = context.local_events.send(
        json!({
            "type": "terminal.output",
            "payload": {
                "terminal_id": context.terminal_id,
                "data_base64": payload.clone(),
            }
        })
        .to_string(),
    );

    if !context.remote_sync {
        return Ok(());
    }

    let url = format!(
        "{}/api/v1/desktop/terminals/{}/output",
        context.backend_base_url, context.terminal_id
    );
    context
        .client
        .post(url)
        .json(&json!({
            "device_id": context.device_id,
            "data_base64": payload,
            "timestamp": Utc::now(),
        }))
        .send()
        .await?
        .error_for_status()?;
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    use serde_json::Value;
    use tokio::{
        sync::{broadcast, mpsc::unbounded_channel},
        time::{timeout, Duration as TokioDuration},
    };

    fn test_manager(events: broadcast::Sender<String>) -> TerminalManager {
        TerminalManager::new(
            "http://127.0.0.1:0".to_string(),
            Uuid::new_v4().to_string(),
            events,
            std::env::temp_dir().join("sirix-terminal-tests"),
        )
    }

    async fn next_event(receiver: &mut broadcast::Receiver<String>) -> Value {
        let payload = timeout(TokioDuration::from_secs(1), receiver.recv())
            .await
            .expect("event should arrive before timeout")
            .expect("broadcast receive should succeed");
        serde_json::from_str(&payload).expect("event payload should be valid json")
    }

    #[tokio::test]
    async fn hosted_terminal_relays_input_resize_and_close() {
        let (events, _) = broadcast::channel(16);
        let mut event_receiver = events.subscribe();
        let manager = test_manager(events);
        let terminal_id = Uuid::new_v4();

        let session = manager
            .create_hosted_terminal(
                terminal_id,
                "/bin/zsh".to_string(),
                "/tmp".to_string(),
                "Sirix Terminal".to_string(),
                120,
                32,
                false,
            )
            .await
            .expect("hosted terminal should be created");

        let opening_event = next_event(&mut event_receiver).await;
        assert_eq!(opening_event["type"], "terminal.ready");
        assert_eq!(
            opening_event["payload"]["terminal_id"],
            terminal_id.to_string()
        );
        assert_eq!(
            opening_event["payload"]["source"],
            TerminalSessionSource::Hosted.as_api_str()
        );
        assert_eq!(opening_event["payload"]["state"], "opening");

        let snapshot = manager
            .get_snapshot(terminal_id)
            .await
            .expect("opening snapshot should exist");
        assert_eq!(snapshot.source, TerminalSessionSource::Hosted.as_api_str());
        assert_eq!(
            manager.session_source(terminal_id).await,
            Some(TerminalSessionSource::Hosted)
        );
        assert_eq!(snapshot.state, "opening");

        let (command_sender, mut command_receiver) = unbounded_channel();
        manager
            .register_hosted_terminal(terminal_id, &session.host_token, command_sender)
            .await
            .expect("host should register");

        let active_event = next_event(&mut event_receiver).await;
        assert_eq!(active_event["type"], "terminal.ready");
        assert_eq!(active_event["payload"]["state"], "active");

        manager
            .write_input(terminal_id, &BASE64.encode("ls\n"))
            .await
            .expect("input should relay to host");
        let HostedTerminalCommand::Input {
            terminal_id: input_terminal_id,
            data_base64,
        } = command_receiver
            .recv()
            .await
            .expect("input command should exist")
        else {
            panic!("expected input command");
        };
        assert_eq!(input_terminal_id, terminal_id);
        assert_eq!(
            BASE64
                .decode(data_base64)
                .expect("input payload should decode"),
            b"ls\n"
        );

        manager
            .resize(terminal_id, 140, 40)
            .await
            .expect("resize should relay to host");
        let HostedTerminalCommand::Resize {
            terminal_id: resize_terminal_id,
            cols,
            rows,
        } = command_receiver
            .recv()
            .await
            .expect("resize command should exist")
        else {
            panic!("expected resize command");
        };
        assert_eq!(resize_terminal_id, terminal_id);
        assert_eq!((cols, rows), (140, 40));

        let resized_snapshot = manager
            .get_snapshot(terminal_id)
            .await
            .expect("resized snapshot should exist");
        assert_eq!((resized_snapshot.cols, resized_snapshot.rows), (140, 40));

        manager
            .close(terminal_id)
            .await
            .expect("close should succeed");
        let HostedTerminalCommand::Close {
            terminal_id: close_terminal_id,
        } = command_receiver
            .recv()
            .await
            .expect("close command should exist")
        else {
            panic!("expected close command");
        };
        assert_eq!(close_terminal_id, terminal_id);

        let closed_event = next_event(&mut event_receiver).await;
        assert_eq!(closed_event["type"], "terminal.closed");
        assert_eq!(
            closed_event["payload"]["terminal_id"],
            terminal_id.to_string()
        );
        assert!(manager.get_snapshot(terminal_id).await.is_none());
    }

    #[tokio::test]
    async fn hosted_terminal_rejects_invalid_registration_token() {
        let (events, _) = broadcast::channel(8);
        let manager = test_manager(events);
        let terminal_id = Uuid::new_v4();

        manager
            .create_hosted_terminal(
                terminal_id,
                "shell".to_string(),
                "/tmp".to_string(),
                "Sirix Terminal".to_string(),
                120,
                32,
                false,
            )
            .await
            .expect("hosted terminal should be created");

        let (command_sender, _) = unbounded_channel();
        let error = manager
            .register_hosted_terminal(terminal_id, "wrong-token", command_sender)
            .await
            .expect_err("registration should fail");
        assert!(error
            .to_string()
            .contains("invalid hosted terminal registration token"));
    }

    #[tokio::test]
    async fn hosted_terminal_disconnect_emits_error_event() {
        let (events, _) = broadcast::channel(16);
        let mut event_receiver = events.subscribe();
        let manager = test_manager(events);
        let terminal_id = Uuid::new_v4();

        let session = manager
            .create_hosted_terminal(
                terminal_id,
                "shell".to_string(),
                "/tmp".to_string(),
                "Sirix Terminal".to_string(),
                120,
                32,
                false,
            )
            .await
            .expect("hosted terminal should be created");
        let _ = next_event(&mut event_receiver).await;

        let (command_sender, _) = unbounded_channel();
        manager
            .register_hosted_terminal(terminal_id, &session.host_token, command_sender)
            .await
            .expect("registration should succeed");
        let _ = next_event(&mut event_receiver).await;

        manager
            .hosted_terminal_disconnected(terminal_id)
            .await
            .expect("disconnect cleanup should succeed");

        let error_event = next_event(&mut event_receiver).await;
        assert_eq!(error_event["type"], "terminal.error");
        assert_eq!(
            error_event["payload"]["terminal_id"],
            terminal_id.to_string()
        );
        assert_eq!(
            error_event["payload"]["error_message"],
            "hosted terminal connection dropped"
        );
        assert!(manager.get_snapshot(terminal_id).await.is_none());
    }
}
