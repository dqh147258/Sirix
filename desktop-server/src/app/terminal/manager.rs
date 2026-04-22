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

use crate::app::{
    ai::config::{AiLaunchConfig, SIRIX_CONFIG_OVERRIDES_PATH_ENV, SIRIX_EXEC_POLICY_PATH_ENV},
    terminal::geometry_arbiter::{
        GeometryAuthoritySource, GeometryUpdate, TerminalClientKind, TerminalGeometryArbiter,
    },
    terminal::state_cache::{
        ResizeReplayMetadata, TerminalOutboundEvent, TerminalReadyV2Payload, TerminalSyncState,
        V2_SYNC_MODE,
    },
};
use crate::scene::{resolve_scene, SIRIX_SCENE_ENV};

type SharedMaster = Arc<Mutex<Box<dyn MasterPty + Send>>>;
type SharedWriter = Arc<Mutex<Box<dyn Write + Send>>>;
type SharedChild = Arc<Mutex<Box<dyn Child + Send + Sync>>>;
type SharedReplayBuffer = Arc<Mutex<TerminalReplayBuffer>>;
type SharedSyncState = Arc<Mutex<TerminalSyncState>>;
type SharedHostedControlSender = Arc<Mutex<Option<UnboundedSender<HostedTerminalCommand>>>>;
type SharedResizePublishFingerprint = Arc<Mutex<Option<ResizePublishFingerprint>>>;

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
    sync_state: SharedSyncState,
    last_resize_publish: SharedResizePublishFingerprint,
    remote_sync: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ResizePublishFingerprint {
    authority_source: GeometryAuthoritySource,
    geometry_generation: u64,
    layout_epoch: u64,
    buffer_epoch: u64,
    rows: u16,
    cols: u16,
    history_generation: Option<u64>,
    history_start_line: Option<i64>,
    history_end_line: Option<i64>,
}

impl ResizePublishFingerprint {
    fn from_resize_bundle(
        events: &[TerminalOutboundEvent],
        authority_source: GeometryAuthoritySource,
        geometry_generation: u64,
        layout_epoch: u64,
        rows: u16,
        cols: u16,
    ) -> Option<Self> {
        let mut saw_resize_bundle_event = false;
        let mut buffer_epoch = 0_u64;
        let mut history_generation = None;
        let mut history_start_line = None;
        let mut history_end_line = None;

        for event in events {
            match event.event_type {
                "terminal.layout.changed" => {
                    saw_resize_bundle_event = true;
                }
                "terminal.buffer.changed" => {
                    if let Some(epoch) = event.payload.get("buffer_epoch").and_then(|v| v.as_u64())
                    {
                        buffer_epoch = epoch;
                    }
                }
                "terminal.screen.snapshot" => {
                    saw_resize_bundle_event = true;
                    if let Some(epoch) = event.payload.get("buffer_epoch").and_then(|v| v.as_u64())
                    {
                        buffer_epoch = epoch;
                    }
                }
                "terminal.state.snapshot" => {
                    saw_resize_bundle_event = true;
                    if let Some(epoch) = event.payload.get("buffer_epoch").and_then(|v| v.as_u64())
                    {
                        buffer_epoch = epoch;
                    }
                    if let Some(main) = event.payload.get("main") {
                        history_generation =
                            main.get("history_generation").and_then(|v| v.as_u64());
                        history_start_line =
                            main.get("history_start_line").and_then(|v| v.as_i64());
                        history_end_line = main.get("history_end_line").and_then(|v| v.as_i64());
                    }
                }
                "terminal.history.invalidated" => {
                    saw_resize_bundle_event = true;
                    history_generation = event
                        .payload
                        .get("history_generation")
                        .and_then(|v| v.as_u64());
                    history_start_line = event
                        .payload
                        .get("history_start_line")
                        .and_then(|v| v.as_i64());
                    history_end_line = event
                        .payload
                        .get("history_end_line")
                        .and_then(|v| v.as_i64());
                }
                _ => {}
            }
        }

        if !saw_resize_bundle_event {
            return None;
        }

        Some(Self {
            authority_source,
            geometry_generation,
            layout_epoch,
            buffer_epoch,
            rows,
            cols,
            history_generation,
            history_start_line,
            history_end_line,
        })
    }
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
    geometry: TerminalGeometryArbiter,
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
    sync_state: SharedSyncState,
    remote_sync: bool,
}

#[derive(Debug, Default)]
struct TerminalReplayBuffer {
    bytes: VecDeque<u8>,
    latest_sequence: u64,
    history_truncated: bool,
}

impl TerminalReplayBuffer {
    fn append(&mut self, chunk: &[u8]) -> u64 {
        if chunk.is_empty() {
            return self.latest_sequence;
        }

        self.latest_sequence = self.latest_sequence.saturating_add(1);

        if chunk.len() >= TERMINAL_OUTPUT_REPLAY_MAX_BYTES {
            self.bytes.clear();
            self.bytes.extend(
                chunk[chunk.len() - TERMINAL_OUTPUT_REPLAY_MAX_BYTES..]
                    .iter()
                    .copied(),
            );
            self.history_truncated = true;
            return self.latest_sequence;
        }

        let overflow = self
            .bytes
            .len()
            .saturating_add(chunk.len())
            .saturating_sub(TERMINAL_OUTPUT_REPLAY_MAX_BYTES);
        for _ in 0..overflow {
            let _ = self.bytes.pop_front();
        }
        if overflow > 0 {
            self.history_truncated = true;
        }

        self.bytes.extend(chunk.iter().copied());
        self.latest_sequence
    }

    fn snapshot(&self) -> Option<LocalTerminalOutputSnapshot> {
        if self.bytes.is_empty() {
            return None;
        }

        Some(LocalTerminalOutputSnapshot {
            bytes: self.bytes.iter().copied().collect(),
            latest_sequence: self.latest_sequence,
            history_truncated: self.history_truncated,
        })
    }
}

#[derive(Debug, Clone)]
pub struct LocalTerminalOutputSnapshot {
    pub bytes: Vec<u8>,
    pub latest_sequence: u64,
    pub history_truncated: bool,
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
    pub latest_output_sequence: u64,
    pub history_truncated: bool,
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

    pub async fn register_viewer(
        &self,
        terminal_id: Uuid,
        client_kind: TerminalClientKind,
    ) -> anyhow::Result<u64> {
        let sessions = self.sessions.read().await;
        let handle = sessions
            .get(&terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
        let mut metadata = handle
            .metadata
            .lock()
            .map_err(|_| anyhow::anyhow!("terminal metadata poisoned"))?;
        Ok(metadata.geometry.register_viewer(client_kind))
    }

    pub async fn unregister_viewer(
        &self,
        terminal_id: Uuid,
        client_kind: TerminalClientKind,
    ) -> anyhow::Result<()> {
        self.unregister_viewer_if_epoch(terminal_id, client_kind, None)
            .await
    }

    pub async fn unregister_viewer_if_epoch(
        &self,
        terminal_id: Uuid,
        client_kind: TerminalClientKind,
        expected_epoch: Option<u64>,
    ) -> anyhow::Result<()> {
        let geometry_update = {
            let sessions = self.sessions.read().await;
            let handle = sessions
                .get(&terminal_id)
                .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
            let mut metadata = handle
                .metadata
                .lock()
                .map_err(|_| anyhow::anyhow!("terminal metadata poisoned"))?;
            match metadata
                .geometry
                .unregister_viewer(client_kind, expected_epoch)
            {
                Ok(update) => update,
                Err(_) => return Ok(()),
            }
        };

        if let Some(update) = geometry_update {
            self.apply_geometry_update(terminal_id, update).await?;
        }
        Ok(())
    }

    pub async fn resize(&self, terminal_id: Uuid, cols: u16, rows: u16) -> anyhow::Result<()> {
        self.resize_from_client(terminal_id, cols, rows, TerminalClientKind::Unknown)
            .await
    }

    pub async fn resize_from_client(
        &self,
        terminal_id: Uuid,
        cols: u16,
        rows: u16,
        client_kind: TerminalClientKind,
    ) -> anyhow::Result<()> {
        self.resize_from_client_if_epoch(terminal_id, cols, rows, client_kind, None)
            .await
    }

    pub async fn resize_from_client_if_epoch(
        &self,
        terminal_id: Uuid,
        cols: u16,
        rows: u16,
        client_kind: TerminalClientKind,
        expected_epoch: Option<u64>,
    ) -> anyhow::Result<()> {
        let geometry_update = {
            let sessions = self.sessions.read().await;
            let handle = sessions
                .get(&terminal_id)
                .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
            let mut metadata = handle
                .metadata
                .lock()
                .map_err(|_| anyhow::anyhow!("terminal metadata poisoned"))?;
            match metadata
                .geometry
                .update_viewer_size(client_kind, cols, rows, expected_epoch)
            {
                Ok(update) => update,
                Err(current_epoch) => {
                    info!(
                        terminal_id = %terminal_id,
                        expected_epoch,
                        current_epoch,
                        client_kind = match client_kind {
                            TerminalClientKind::SystemTerminal => "system_terminal",
                            TerminalClientKind::DesktopApp => "desktop_app",
                            TerminalClientKind::MobileApp => "mobile_app",
                            TerminalClientKind::Unknown => "unknown",
                        },
                        "[TERMINAL_HISTORY_TRACE] ignore stale viewer resize"
                    );
                    return Ok(());
                }
            }
        };

        if let Some(update) = geometry_update {
            self.apply_geometry_update(terminal_id, update).await?;
        }
        Ok(())
    }

    async fn apply_geometry_update(
        &self,
        terminal_id: Uuid,
        update: GeometryUpdate,
    ) -> anyhow::Result<()> {
        info!(
            terminal_id = %terminal_id,
            previous_cols = update.previous_size.cols,
            previous_rows = update.previous_size.rows,
            cols = update.size.cols,
            rows = update.size.rows,
            previous_source = update.previous_source.as_api_str(),
            authority_source = update.authority_source.as_api_str(),
            geometry_generation = update.geometry_generation,
            pty_size_changed = update.pty_size_changed(),
            "[TERMINAL_HISTORY_TRACE] apply geometry update"
        );
        if update.pty_size_changed() {
            return self.resize_internal(terminal_id, update).await;
        }

        let (remote_sync, layout_epoch) = {
            let sessions = self.sessions.read().await;
            let handle = sessions
                .get(&terminal_id)
                .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
            let layout_epoch = handle
                .sync_state
                .lock()
                .map_err(|_| anyhow::anyhow!("terminal sync state poisoned"))?
                .current_layout_epoch();
            (handle.remote_sync, layout_epoch)
        };

        self.publish_geometry_changed(
            terminal_id,
            update.size.cols,
            update.size.rows,
            update.authority_source,
            update.geometry_generation,
            layout_epoch,
            remote_sync,
        )
        .await
    }

    async fn resize_internal(
        &self,
        terminal_id: Uuid,
        update: GeometryUpdate,
    ) -> anyhow::Result<()> {
        let cols = update.size.cols;
        let rows = update.size.rows;
        let (remote_sync, layout_epoch, events, publish_fingerprint, last_resize_publish) = {
            let sessions = self.sessions.read().await;
            let handle = sessions
                .get(&terminal_id)
                .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
            let remote_sync = handle.remote_sync;
            let replay_snapshot = handle
                .replay_buffer
                .lock()
                .ok()
                .and_then(|replay| replay.snapshot());

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
            let mut sync_state = handle
                .sync_state
                .lock()
                .map_err(|_| anyhow::anyhow!("terminal sync state poisoned"))?;
            let layout_epoch = sync_state.current_layout_epoch().saturating_add(1);
            let replay_metadata = ResizeReplayMetadata {
                history_truncated: replay_snapshot
                    .as_ref()
                    .is_some_and(|snapshot| snapshot.history_truncated),
                replay_byte_len: replay_snapshot
                    .as_ref()
                    .map_or(0, |snapshot| snapshot.bytes.len()),
                buffer_epoch: sync_state.current_buffer_epoch(),
                layout_epoch: sync_state.current_layout_epoch(),
            };
            let events = sync_state.resize_with_replay_metadata(
                terminal_id,
                rows,
                cols,
                replay_snapshot
                    .as_ref()
                    .map(|snapshot| snapshot.bytes.as_slice()),
                replay_metadata,
            );
            let publish_fingerprint = ResizePublishFingerprint::from_resize_bundle(
                &events,
                update.authority_source,
                update.geometry_generation,
                layout_epoch,
                rows,
                cols,
            );
            (
                remote_sync,
                layout_epoch,
                events,
                publish_fingerprint,
                handle.last_resize_publish.clone(),
            )
        };
        if let Some(fingerprint) = publish_fingerprint {
            let mut guard = last_resize_publish
                .lock()
                .map_err(|_| anyhow::anyhow!("terminal resize publish fingerprint poisoned"))?;
            if guard.as_ref() == Some(&fingerprint) {
                info!(
                    terminal_id = %terminal_id,
                    authority_source = update.authority_source.as_api_str(),
                    geometry_generation = update.geometry_generation,
                    layout_epoch,
                    rows,
                    cols,
                    history_generation = fingerprint.history_generation,
                    "[TERMINAL_HISTORY_TRACE] skip duplicate resize publish bundle"
                );
                return Ok(());
            }
            *guard = Some(fingerprint);
        }
        self.publish_v2_events(terminal_id, events, remote_sync)
            .await?;
        self.publish_geometry_changed(
            terminal_id,
            cols,
            rows,
            update.authority_source,
            update.geometry_generation,
            layout_epoch,
            remote_sync,
        )
        .await?;
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
            geometry: TerminalGeometryArbiter::new_host_authority(cols, rows),
            created_at: Utc::now(),
            closed_at: None,
        }));
        let replay_buffer = Arc::new(Mutex::new(TerminalReplayBuffer::default()));
        let sync_state = Arc::new(Mutex::new(TerminalSyncState::new(rows, cols)));
        self.sessions.write().await.insert(
            terminal_id,
            TerminalSessionHandle {
                endpoint: TerminalSessionEndpoint::Hosted {
                    host_token: host_token.clone(),
                    control_sender: Arc::new(Mutex::new(None)),
                },
                metadata,
                replay_buffer,
                sync_state,
                last_resize_publish: Arc::new(Mutex::new(None)),
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
        info!(
            terminal_id = %terminal_id,
            cols,
            rows,
            "[TERMINAL_HISTORY_TRACE] hosted terminal reported system resize"
        );
        let geometry_update = {
            let sessions = self.sessions.read().await;
            let handle = sessions
                .get(&terminal_id)
                .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
            let TerminalSessionEndpoint::Hosted { .. } = &handle.endpoint else {
                anyhow::bail!("terminal session is not hosted");
            };
            let mut metadata = handle
                .metadata
                .lock()
                .map_err(|_| anyhow::anyhow!("terminal metadata poisoned"))?;
            metadata.geometry.update_host_size(cols, rows)
        };

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
        .await?;
        if let Some(update) = geometry_update {
            self.apply_geometry_update(terminal_id, update).await?;
        }
        Ok(())
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
        let replay = handle.replay_buffer.lock().ok()?;
        Some(LocalTerminalSnapshot {
            terminal_id,
            device_id: self.device_id.clone(),
            title: metadata.title,
            source: handle.endpoint.source().as_api_str().to_string(),
            shell: metadata.shell,
            cwd: metadata.cwd,
            state: metadata.state,
            cols: i32::from(metadata.geometry.cols()),
            rows: i32::from(metadata.geometry.rows()),
            created_at: metadata.created_at,
            closed_at: metadata.closed_at,
            latest_output_sequence: replay.latest_sequence,
            history_truncated: replay.history_truncated,
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
                    cols: i32::from(metadata.geometry.cols()),
                    rows: i32::from(metadata.geometry.rows()),
                    created_at: metadata.created_at,
                    closed_at: metadata.closed_at,
                    latest_output_sequence: handle
                        .replay_buffer
                        .lock()
                        .map(|replay| replay.latest_sequence)
                        .unwrap_or_default(),
                    history_truncated: handle
                        .replay_buffer
                        .lock()
                        .map(|replay| replay.history_truncated)
                        .unwrap_or(false),
                });
            }
        }
        items.sort_by(|left, right| left.created_at.cmp(&right.created_at));
        items
    }

    pub async fn get_output_snapshot(
        &self,
        terminal_id: Uuid,
    ) -> Option<LocalTerminalOutputSnapshot> {
        let sessions = self.sessions.read().await;
        let handle = sessions.get(&terminal_id)?;
        let replay = handle.replay_buffer.lock().ok()?;
        replay.snapshot()
    }

    pub async fn bootstrap_v2(
        &self,
        terminal_id: Uuid,
        viewer_presence_epoch: Option<u64>,
    ) -> anyhow::Result<Vec<serde_json::Value>> {
        let sessions = self.sessions.read().await;
        let handle = sessions
            .get(&terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
        let metadata = handle
            .metadata
            .lock()
            .map_err(|_| anyhow::anyhow!("terminal metadata poisoned"))?
            .clone();
        let ready = TerminalReadyV2Payload {
            terminal_id,
            device_id: self.device_id.clone(),
            title: metadata.title.clone(),
            source: handle.endpoint.source().as_api_str().to_string(),
            shell: metadata.shell.clone(),
            cwd: metadata.cwd.clone(),
            state: metadata.state.clone(),
            session_state: metadata.state.clone(),
            cols: i32::from(metadata.geometry.cols()),
            rows: i32::from(metadata.geometry.rows()),
            created_at: metadata.created_at,
            closed_at: metadata.closed_at,
            geometry_generation: metadata.geometry.geometry_generation(),
            authority_source: metadata
                .geometry
                .authority_source()
                .as_api_str()
                .to_string(),
            viewer_presence_epoch,
            protocol_version: 2,
            sync_mode: V2_SYNC_MODE,
        };
        let mut sync_state = handle
            .sync_state
            .lock()
            .map_err(|_| anyhow::anyhow!("terminal sync state poisoned"))?;
        let mut messages = sync_state
            .bootstrap_events(ready)
            .into_iter()
            .map(TerminalOutboundEvent::into_message)
            .collect::<Vec<_>>();

        if let Ok(replay) = handle.replay_buffer.lock() {
            if let Some(snapshot) = replay.snapshot() {
                // V2 bootstrap 之前只下发 authority screen snapshot，Flutter 端首次 attach
                // 到共享终端时只能拿到“当前屏幕”的 76 行左右内容，后续 resize 即使
                // 不再 replace，也只剩这一小段本地 scrollback 可供 reflow，表现为
                // 一拖动窗口历史消息就像丢失。这里把完整 replay snapshot 追加到
                // bootstrap 末尾，让客户端先拿到 authority 元数据，再用原始输出流
                // 重建完整本地 scrollback，后续 resize 才有足够历史可保留。
                if !snapshot.history_truncated {
                    messages.push(serde_json::json!({
                        "type": "terminal.snapshot",
                        "payload": {
                            "terminal_id": terminal_id,
                            "data_base64": BASE64.encode(&snapshot.bytes),
                            "stream_sequence": snapshot.latest_sequence,
                            "history_truncated": false,
                        }
                    }));
                }
            }
        }

        Ok(messages)
    }

    pub async fn history_range_response(
        &self,
        terminal_id: Uuid,
        request_id: String,
        expected_history_generation: Option<u64>,
        start_line: i64,
        end_line: i64,
    ) -> anyhow::Result<serde_json::Value> {
        let sessions = self.sessions.read().await;
        let handle = sessions
            .get(&terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal session not found"))?;
        let sync_state = handle
            .sync_state
            .lock()
            .map_err(|_| anyhow::anyhow!("terminal sync state poisoned"))?;
        if let Some(expected_history_generation) = expected_history_generation {
            let current_generation = sync_state.current_history_generation();
            if current_generation != expected_history_generation {
                return Ok(sync_state
                    .history_generation_mismatch(
                        terminal_id,
                        request_id,
                        expected_history_generation,
                    )
                    .into_message());
            }
        }
        Ok(sync_state
            .history_range_response(terminal_id, request_id, start_line, end_line)
            .into_message())
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
            let (geometry_generation, authority_source) = {
                let sessions = self.sessions.read().await;
                if let Some(handle) = sessions.get(&terminal_id) {
                    if let Ok(metadata) = handle.metadata.lock() {
                        (
                            metadata.geometry.geometry_generation(),
                            metadata
                                .geometry
                                .authority_source()
                                .as_api_str()
                                .to_string(),
                        )
                    } else {
                        (0, "server_default".to_string())
                    }
                } else {
                    (0, "server_default".to_string())
                }
            };
            let ready = TerminalReadyV2Payload {
                terminal_id,
                device_id: snapshot.device_id,
                title: snapshot.title,
                source: snapshot.source,
                shell: snapshot.shell,
                cwd: snapshot.cwd,
                state: snapshot.state.clone(),
                session_state: snapshot.state,
                cols: snapshot.cols,
                rows: snapshot.rows,
                created_at: snapshot.created_at,
                closed_at: snapshot.closed_at,
                geometry_generation,
                authority_source,
                viewer_presence_epoch: None,
                protocol_version: 2,
                sync_mode: V2_SYNC_MODE,
            };
            self.publish_local_terminal_event("terminal.ready", json!(ready));
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

    async fn publish_geometry_changed(
        &self,
        terminal_id: Uuid,
        cols: u16,
        rows: u16,
        authority_source: GeometryAuthoritySource,
        geometry_generation: u64,
        layout_epoch: u64,
        remote_sync: bool,
    ) -> anyhow::Result<()> {
        let event = json!({
            "type": "terminal.geometry.changed",
            "payload": {
                "terminal_id": terminal_id,
                "cols": cols,
                "rows": rows,
                "authority_source": authority_source.as_api_str(),
                "geometry_generation": geometry_generation,
                "layout_epoch": layout_epoch,
            }
        });
        let _ = self.local_events.send(event.to_string());
        if remote_sync {
            self.push_remote_terminal_event(terminal_id, event).await?;
        }
        Ok(())
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
        builder.env("PATH", &augmented_path);
        builder.env("SIRIX_HOME", &self.sirix_home);
        if let Ok(scene) = resolve_scene() {
            builder.env(SIRIX_SCENE_ENV, scene.as_str());
        }
        // Ordinary local shells should still open even when the optional
        // Sirix AI runtime binary is not bundled on the current machine. The
        // runtime executable is required for explicit AI-session launch flows,
        // which already call `resolve_codex_executable()` on their own path.
        // For a normal dashboard terminal we only inject the variable when the
        // runtime can actually be resolved, instead of failing terminal
        // creation before the PTY even starts.
        if let Ok(runtime_executable) = resolve_codex_executable() {
            builder.env("SIRIX_CODEX_EXECUTABLE", runtime_executable);
        }
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
            geometry: TerminalGeometryArbiter::new(cols, rows),
            created_at: Utc::now(),
            closed_at: None,
        }));
        let replay_buffer = Arc::new(Mutex::new(TerminalReplayBuffer::default()));
        let sync_state = Arc::new(Mutex::new(TerminalSyncState::new(rows, cols)));

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
                sync_state: sync_state.clone(),
                last_resize_publish: Arc::new(Mutex::new(None)),
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
            sync_state: sync_state.clone(),
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
            sync_state: handle.sync_state.clone(),
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

    async fn publish_v2_events(
        &self,
        terminal_id: Uuid,
        events: Vec<TerminalOutboundEvent>,
        remote_sync: bool,
    ) -> anyhow::Result<()> {
        for event in events {
            let message = event.into_message();
            let _ = self.local_events.send(message.to_string());
            if remote_sync {
                self.push_remote_terminal_event(terminal_id, message)
                    .await?;
            }
        }
        Ok(())
    }

    async fn push_remote_terminal_event(
        &self,
        terminal_id: Uuid,
        event: serde_json::Value,
    ) -> anyhow::Result<()> {
        let url = format!(
            "{}/api/v1/desktop/terminals/{}/events",
            self.backend_base_url, terminal_id
        );
        self.client
            .post(url)
            .json(&json!({
                "device_id": self.device_id,
                "event": event,
            }))
            .send()
            .await?
            .error_for_status()?;
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
    let sequence = if let Ok(mut replay) = context.replay_buffer.lock() {
        replay.append(&snapshot)
    } else {
        0
    };

    let payload = BASE64.encode(&snapshot);
    pending.clear();
    let _ = context.local_events.send(
        json!({
            "type": "terminal.output",
            "payload": {
                "terminal_id": context.terminal_id,
                "data_base64": payload.clone(),
                "stream_sequence": sequence,
            }
        })
        .to_string(),
    );

    let v2_events = if let Ok(mut sync_state) = context.sync_state.lock() {
        sync_state.apply_output(context.terminal_id, &snapshot)
    } else {
        Vec::new()
    };
    for event in v2_events {
        let payload = event.into_message();
        let _ = context.local_events.send(payload.to_string());
        if context.remote_sync {
            push_remote_terminal_event(
                &context.client,
                &context.backend_base_url,
                &context.device_id,
                context.terminal_id,
                payload.clone(),
                runtime,
            )?;
        }
    }

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
                "stream_sequence": sequence,
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
    let sequence = if let Ok(mut replay) = context.replay_buffer.lock() {
        replay.append(chunk)
    } else {
        0
    };

    let payload = BASE64.encode(chunk);
    let _ = context.local_events.send(
        json!({
            "type": "terminal.output",
            "payload": {
                "terminal_id": context.terminal_id,
                "data_base64": payload.clone(),
                "stream_sequence": sequence,
            }
        })
        .to_string(),
    );

    let v2_events = if let Ok(mut sync_state) = context.sync_state.lock() {
        sync_state.apply_output(context.terminal_id, chunk)
    } else {
        Vec::new()
    };
    for event in v2_events {
        let payload = event.into_message();
        let _ = context.local_events.send(payload.to_string());
        if context.remote_sync {
            let url = format!(
                "{}/api/v1/desktop/terminals/{}/events",
                context.backend_base_url, context.terminal_id
            );
            context
                .client
                .post(url)
                .json(&json!({
                    "device_id": context.device_id,
                    "event": payload,
                }))
                .send()
                .await?
                .error_for_status()?;
        }
    }

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
            "stream_sequence": sequence,
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

fn push_remote_terminal_event(
    client: &reqwest::Client,
    backend_base_url: &str,
    device_id: &str,
    terminal_id: Uuid,
    event: serde_json::Value,
    runtime: &tokio::runtime::Handle,
) -> anyhow::Result<()> {
    runtime.block_on(async {
        let url = format!(
            "{}/api/v1/desktop/terminals/{}/events",
            backend_base_url, terminal_id
        );
        client
            .post(url)
            .json(&json!({
                "device_id": device_id,
                "event": event,
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
    let scene = crate::scene::resolve_scene()?;
    let runtime_name = if cfg!(windows) {
        "sirix-runtime.exe"
    } else {
        "sirix-runtime"
    };

    if let Ok(current_exe) = env::current_exe() {
        if let Some(parent) = current_exe.parent() {
            let runtime = parent.join(runtime_name);
            if runtime.is_file()
                && parent
                    .file_name()
                    .and_then(|segment| segment.to_str())
                    .is_some_and(|segment| segment == scene.runtime_profile())
            {
                return Ok(runtime.display().to_string());
            }
        }
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let runtime = manifest_dir
        .join("..")
        .join("third_party")
        .join("codex-rs")
        .join("target")
        .join(scene.runtime_profile())
        .join(runtime_name);
    if runtime.is_file() {
        return Ok(runtime.display().to_string());
    }

    if executable_in_path(runtime_name) {
        return Ok(runtime_name.to_string());
    }

    anyhow::bail!(
        "Sirix AI runtime executable not found for scene {}. Expected `{}` next to the matching app profile, in `third_party/codex-rs/target/{}`, or on PATH.",
        scene.as_str(),
        runtime_name,
        scene.runtime_profile()
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

    async fn next_event_of_type(
        receiver: &mut broadcast::Receiver<String>,
        event_type: &str,
    ) -> Value {
        loop {
            let event = next_event(receiver).await;
            if event["type"] == event_type {
                return event;
            }
        }
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

        let closed_event = next_event_of_type(&mut event_receiver, "terminal.closed").await;
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

    #[tokio::test]
    async fn bootstrap_v2_includes_socket_local_viewer_presence_epoch() {
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

        let messages = manager
            .bootstrap_v2(terminal_id, Some(7))
            .await
            .expect("bootstrap should succeed");
        let ready = messages
            .iter()
            .find(|message| message["type"] == "terminal.ready")
            .expect("bootstrap should contain terminal.ready");

        assert_eq!(ready["payload"]["viewer_presence_epoch"], 7);
    }

    #[tokio::test]
    async fn bootstrap_v2_includes_canonical_history_preview_for_existing_output() {
        let (events, _) = broadcast::channel(8);
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
        let (command_sender, _) = unbounded_channel();
        manager
            .register_hosted_terminal(terminal_id, &session.host_token, command_sender)
            .await
            .expect("host should register");
        manager
            .ingest_hosted_output(
                terminal_id,
                &BASE64.encode("alpha\r\nbeta\r\ngamma\r\ndelta\r\n"),
            )
            .await
            .expect("hosted output should ingest");

        let messages = manager
            .bootstrap_v2(terminal_id, Some(9))
            .await
            .expect("bootstrap should succeed");
        let preview = messages
            .iter()
            .find(|message| message["type"] == "terminal.history.invalidated")
            .expect("bootstrap should include canonical history preview");
        let lines = preview["payload"]["lines"]
            .as_array()
            .expect("preview lines should be an array");

        assert_eq!(preview["payload"]["reason"], "bootstrap");
        assert!(!lines.is_empty());
    }

    #[tokio::test]
    async fn desktop_viewer_resize_is_ignored_while_hosted_terminal_has_system_authority() {
        let (events, _) = broadcast::channel(16);
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

        let (command_sender, mut command_receiver) = unbounded_channel();
        manager
            .register_hosted_terminal(terminal_id, &session.host_token, command_sender)
            .await
            .expect("host should register");

        let epoch = manager
            .register_viewer(terminal_id, TerminalClientKind::DesktopApp)
            .await
            .expect("viewer should register");
        assert!(epoch > 0);

        manager
            .resize_from_client_if_epoch(
                terminal_id,
                140,
                40,
                TerminalClientKind::DesktopApp,
                Some(epoch.saturating_sub(1)),
            )
            .await
            .expect("stale resize should be ignored without error");

        assert!(
            timeout(TokioDuration::from_millis(100), command_receiver.recv())
                .await
                .is_err(),
            "stale resize must not forward resize command"
        );

        let snapshot = manager
            .get_snapshot(terminal_id)
            .await
            .expect("snapshot should exist");
        assert_eq!((snapshot.cols, snapshot.rows), (120, 32));

        manager
            .resize_from_client_if_epoch(
                terminal_id,
                140,
                40,
                TerminalClientKind::DesktopApp,
                Some(epoch),
            )
            .await
            .expect("current resize should succeed");

        assert!(
            timeout(TokioDuration::from_millis(100), command_receiver.recv())
                .await
                .is_err(),
            "desktop viewer resize must not override the hosted system terminal authority"
        );
        let snapshot = manager
            .get_snapshot(terminal_id)
            .await
            .expect("snapshot should continue using hosted size");
        assert_eq!((snapshot.cols, snapshot.rows), (120, 32));
    }

    #[test]
    fn resize_publish_fingerprint_changes_when_resize_bundle_changes() {
        let events = vec![
            TerminalOutboundEvent::new(
                "terminal.layout.changed",
                &json!({
                    "terminal_id": Uuid::new_v4(),
                    "layout_epoch": 4,
                    "rows": 32,
                    "cols": 120,
                }),
            ),
            TerminalOutboundEvent::new(
                "terminal.state.snapshot",
                &json!({
                    "terminal_id": Uuid::new_v4(),
                    "active_buffer": "main",
                    "buffer_epoch": 2,
                    "layout_epoch": 4,
                    "main": {
                        "history_generation": 9,
                        "history_start_line": 0,
                        "history_end_line": 400,
                        "viewport_start_line": 368,
                        "viewport_end_line": 400,
                    },
                    "alt": { "active": false },
                }),
            ),
            TerminalOutboundEvent::new(
                "terminal.screen.snapshot",
                &json!({
                    "terminal_id": Uuid::new_v4(),
                    "buffer_kind": "main",
                    "buffer_epoch": 2,
                    "layout_epoch": 4,
                    "rows": 32,
                    "cols": 120,
                    "cursor_row": 0,
                    "cursor_col": 0,
                    "screen_data_base64": "",
                    "screen_lines": [],
                }),
            ),
        ];

        let first = ResizePublishFingerprint::from_resize_bundle(
            &events,
            GeometryAuthoritySource::DesktopApp,
            3,
            4,
            32,
            120,
        )
        .expect("layout bundle should produce fingerprint");
        let same = ResizePublishFingerprint::from_resize_bundle(
            &events,
            GeometryAuthoritySource::DesktopApp,
            3,
            4,
            32,
            120,
        )
        .expect("same bundle should produce fingerprint");
        let changed = ResizePublishFingerprint::from_resize_bundle(
            &events,
            GeometryAuthoritySource::DesktopApp,
            4,
            4,
            32,
            120,
        )
        .expect("changed bundle should produce fingerprint");

        assert_eq!(first, same);
        assert_ne!(first, changed);
    }

    #[test]
    fn replay_buffer_marks_truncation_and_tracks_latest_sequence() {
        let mut replay = TerminalReplayBuffer::default();

        assert_eq!(replay.append(b"abc"), 1);
        assert_eq!(replay.latest_sequence, 1);
        assert!(!replay.history_truncated);

        let oversized = vec![b'x'; TERMINAL_OUTPUT_REPLAY_MAX_BYTES + 4];
        assert_eq!(replay.append(&oversized), 2);
        assert!(replay.history_truncated);

        let snapshot = replay
            .snapshot()
            .expect("snapshot should exist after append");
        assert_eq!(snapshot.latest_sequence, 2);
        assert!(snapshot.history_truncated);
        assert_eq!(snapshot.bytes.len(), TERMINAL_OUTPUT_REPLAY_MAX_BYTES);
    }
}
