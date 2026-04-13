use std::{process::Stdio, time::Duration};

use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio::process::Command;

use crate::app::{
    ai::config::{extract_mcp_probe_target, McpProbeTarget},
    state::{AppState, RuntimeState},
};

const MCP_STATUS_TRACE_TAG: &str = "[MCP_STATUS_TRACE]";

#[derive(Debug, Clone, Default)]
pub struct StatusRegistry {
    pub mcp_servers: Vec<McpServerRuntimeStatus>,
    pub last_mcp_probe_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StatusOverviewResponse {
    pub generated_at: DateTime<Utc>,
    pub runtime: RuntimeState,
    pub backend: BackendStatusSummary,
    pub ai: AiStatusSummary,
    pub terminals: TerminalStatusSummary,
    pub mcp: McpStatusSummary,
}

#[derive(Debug, Clone, Serialize)]
pub struct BackendStatusSummary {
    pub connected: bool,
    pub last_healthy_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AiStatusSummary {
    pub active_sessions: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalStatusSummary {
    pub active_terminals: usize,
    pub standalone_page_deprecated: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct McpStatusSummary {
    pub last_probe_at: Option<DateTime<Utc>>,
    pub active_count: usize,
    pub error_count: usize,
    pub servers: Vec<McpServerRuntimeStatus>,
}

#[derive(Debug, Clone, Serialize)]
pub struct McpServerRuntimeStatus {
    pub id: String,
    pub title: String,
    pub transport: String,
    pub enabled: bool,
    pub active: bool,
    pub healthy: bool,
    pub error: Option<String>,
    pub updated_at: DateTime<Utc>,
}

pub async fn refresh_mcp_statuses(state: &AppState) {
    let now = Utc::now();
    let statuses = match state.sirix_config_store.load_global() {
        Ok(config) => {
            let mut next = Vec::new();
            for server in config.mcp_servers.into_iter().filter(|item| item.enabled) {
                let status =
                    probe_mcp_server(&server.id, &server.name, extract_mcp_probe_target(&server))
                        .await;
                next.push(status);
            }
            next
        }
        Err(error) => {
            state.logger.warn(format!(
                "{MCP_STATUS_TRACE_TAG} failed to load sirix config for MCP probe: {error}"
            ));
            vec![McpServerRuntimeStatus {
                id: "config-load".to_string(),
                title: "Config Load".to_string(),
                transport: "internal".to_string(),
                enabled: true,
                active: false,
                healthy: false,
                error: Some(error.to_string()),
                updated_at: now,
            }]
        }
    };

    {
        let mut registry = state.status_registry.write().await;
        registry.mcp_servers = statuses.clone();
        registry.last_mcp_probe_at = Some(now);
    }

    let healthy = statuses.iter().filter(|item| item.healthy).count();
    let unhealthy = statuses.iter().filter(|item| !item.healthy).count();
    state.logger.info(format!(
        "{MCP_STATUS_TRACE_TAG} probe_complete healthy={healthy} unhealthy={unhealthy}"
    ));
}

pub async fn build_status_overview(state: &AppState) -> StatusOverviewResponse {
    let generated_at = Utc::now();
    let runtime = state.runtime.read().await.clone();
    let registry = state.status_registry.read().await.clone();
    let ai_sessions = state.ai_session_registry.list().await;
    let terminal_snapshots = state.terminal_manager.list_snapshots().await;
    let active_count = registry
        .mcp_servers
        .iter()
        .filter(|item| item.active)
        .count();
    let error_count = registry
        .mcp_servers
        .iter()
        .filter(|item| !item.healthy)
        .count();

    StatusOverviewResponse {
        generated_at,
        backend: BackendStatusSummary {
            connected: runtime.backend_event_stream_connected,
            last_healthy_at: runtime.backend_last_healthy_at,
        },
        ai: AiStatusSummary {
            active_sessions: ai_sessions.len(),
        },
        terminals: TerminalStatusSummary {
            active_terminals: terminal_snapshots.len(),
            standalone_page_deprecated: true,
        },
        mcp: McpStatusSummary {
            last_probe_at: registry.last_mcp_probe_at,
            active_count,
            error_count,
            servers: registry.mcp_servers,
        },
        runtime,
    }
}

async fn probe_mcp_server(
    id: &str,
    title: &str,
    target: anyhow::Result<McpProbeTarget>,
) -> McpServerRuntimeStatus {
    let updated_at = Utc::now();
    match target {
        Ok(McpProbeTarget::Http { url }) => {
            let client = reqwest::Client::builder()
                .timeout(Duration::from_secs(3))
                .build();
            match client {
                Ok(client) => match client.get(&url).send().await {
                    Ok(response) => {
                        let code = response.status();
                        let healthy = code.is_success()
                            || code.as_u16() == 401
                            || code.as_u16() == 403
                            || code.as_u16() == 405;
                        McpServerRuntimeStatus {
                            id: id.to_string(),
                            title: title.to_string(),
                            transport: "http".to_string(),
                            enabled: true,
                            active: healthy,
                            healthy,
                            error: (!healthy).then(|| format!("http status {code}")),
                            updated_at,
                        }
                    }
                    Err(error) => McpServerRuntimeStatus {
                        id: id.to_string(),
                        title: title.to_string(),
                        transport: "http".to_string(),
                        enabled: true,
                        active: false,
                        healthy: false,
                        error: Some(error.to_string()),
                        updated_at,
                    },
                },
                Err(error) => McpServerRuntimeStatus {
                    id: id.to_string(),
                    title: title.to_string(),
                    transport: "http".to_string(),
                    enabled: true,
                    active: false,
                    healthy: false,
                    error: Some(error.to_string()),
                    updated_at,
                },
            }
        }
        Ok(McpProbeTarget::Stdio { command, args, env }) => {
            let mut child = match {
                let mut cmd = Command::new(&command);
                cmd.args(&args)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .kill_on_drop(true);
                for (key, value) in env {
                    cmd.env(key, value);
                }
                cmd.spawn()
            } {
                Ok(child) => child,
                Err(error) => {
                    return McpServerRuntimeStatus {
                        id: id.to_string(),
                        title: title.to_string(),
                        transport: "stdio".to_string(),
                        enabled: true,
                        active: false,
                        healthy: false,
                        error: Some(error.to_string()),
                        updated_at,
                    }
                }
            };

            let outcome = tokio::time::timeout(Duration::from_millis(450), child.wait()).await;
            match outcome {
                Err(_) => {
                    let _ = child.kill().await;
                    McpServerRuntimeStatus {
                        id: id.to_string(),
                        title: title.to_string(),
                        transport: "stdio".to_string(),
                        enabled: true,
                        active: true,
                        healthy: true,
                        error: None,
                        updated_at,
                    }
                }
                Ok(Ok(status)) if status.success() => McpServerRuntimeStatus {
                    id: id.to_string(),
                    title: title.to_string(),
                    transport: "stdio".to_string(),
                    enabled: true,
                    active: true,
                    healthy: true,
                    error: None,
                    updated_at,
                },
                Ok(Ok(status)) => McpServerRuntimeStatus {
                    id: id.to_string(),
                    title: title.to_string(),
                    transport: "stdio".to_string(),
                    enabled: true,
                    active: false,
                    healthy: false,
                    error: Some(format!("process exited with status {status}")),
                    updated_at,
                },
                Ok(Err(error)) => McpServerRuntimeStatus {
                    id: id.to_string(),
                    title: title.to_string(),
                    transport: "stdio".to_string(),
                    enabled: true,
                    active: false,
                    healthy: false,
                    error: Some(error.to_string()),
                    updated_at,
                },
            }
        }
        Err(error) => McpServerRuntimeStatus {
            id: id.to_string(),
            title: title.to_string(),
            transport: "unknown".to_string(),
            enabled: true,
            active: false,
            healthy: false,
            error: Some(error.to_string()),
            updated_at,
        },
    }
}
