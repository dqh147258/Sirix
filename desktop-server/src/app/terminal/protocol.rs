use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde::Deserialize;
use serde_json::json;

use crate::app::terminal::geometry_arbiter::TerminalClientKind;
use crate::app::terminal::manager::{LocalTerminalOutputSnapshot, LocalTerminalSnapshot};
use crate::shared_terminal_protocol::{
    AUTHORITY_PROTOCOL_VERSION, AUTHORITY_SYNC_MODE, RAW_STREAM_PROTOCOL_VERSION,
    RAW_STREAM_SYNC_MODE,
};

/// Shared terminal websocket payloads and normalization helpers.
///
/// The current repository still has multiple transports (desktop-local,
/// backend relay, session channel) that ultimately speak the same terminal
/// control language. Keeping the normalization rules here avoids re-encoding
/// those rules ad hoc inside each transport handler and is a small step toward
/// the single authoritative terminal protocol described in the 2026-04-23
/// architecture docs.
#[derive(Debug, Deserialize)]
pub(crate) struct TerminalAttachPayload {
    pub terminal_id: String,
    pub protocol_version: Option<u32>,
    pub sync_mode: Option<String>,
    pub client_kind: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct TerminalBootstrapRequestPayload {
    pub terminal_id: String,
}

#[derive(Debug, Deserialize)]
pub(crate) struct TerminalHistoryRangeRequestPayload {
    pub request_id: String,
    pub terminal_id: String,
    pub history_generation: Option<u64>,
    pub start_line: i64,
    pub end_line: i64,
}

#[derive(Debug, Deserialize)]
pub(crate) struct TerminalResizePayload {
    pub terminal_id: String,
    pub cols: u16,
    pub rows: u16,
    pub client_kind: Option<String>,
    pub viewer_presence_epoch: Option<u64>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct TerminalDetachPayload {
    pub terminal_id: String,
    pub client_kind: Option<String>,
    pub viewer_presence_epoch: Option<u64>,
}

pub(crate) fn attach_payload_terminal_id(
    terminal_id: Option<String>,
    payload: Option<TerminalAttachPayload>,
) -> (Option<String>, u32, Option<String>, TerminalClientKind) {
    match payload {
        Some(payload) => (
            Some(payload.terminal_id),
            payload.protocol_version.unwrap_or(1),
            payload.sync_mode,
            TerminalClientKind::from_wire(payload.client_kind.as_deref()),
        ),
        None => (terminal_id, 1, None, TerminalClientKind::Unknown),
    }
}

pub(crate) fn is_authority_protocol(protocol_version: u32, sync_mode: Option<&str>) -> bool {
    protocol_version == AUTHORITY_PROTOCOL_VERSION && sync_mode == Some(AUTHORITY_SYNC_MODE)
}

pub(crate) fn is_raw_stream_protocol(protocol_version: u32, sync_mode: Option<&str>) -> bool {
    protocol_version == RAW_STREAM_PROTOCOL_VERSION && sync_mode == Some(RAW_STREAM_SYNC_MODE)
}

pub(crate) fn bootstrap_terminal_id(
    terminal_id: Option<String>,
    payload: Option<TerminalBootstrapRequestPayload>,
) -> Option<String> {
    payload.map(|item| item.terminal_id).or(terminal_id)
}

pub(crate) fn history_request_parts(
    request_id: Option<String>,
    terminal_id: Option<String>,
    history_generation: Option<u64>,
    start_line: Option<i64>,
    end_line: Option<i64>,
    payload: Option<TerminalHistoryRangeRequestPayload>,
) -> Option<(String, String, Option<u64>, i64, i64)> {
    if let Some(payload) = payload {
        return Some((
            payload.request_id,
            payload.terminal_id,
            payload.history_generation,
            payload.start_line,
            payload.end_line,
        ));
    }
    Some((
        request_id?,
        terminal_id?,
        history_generation,
        start_line?,
        end_line?,
    ))
}

pub(crate) fn resize_request_parts(
    terminal_id: String,
    cols: u16,
    rows: u16,
    client_kind: Option<String>,
    viewer_presence_epoch: Option<u64>,
    payload: Option<TerminalResizePayload>,
) -> (String, u16, u16, Option<String>, Option<u64>) {
    if let Some(payload) = payload {
        return (
            payload.terminal_id,
            payload.cols,
            payload.rows,
            payload.client_kind,
            payload.viewer_presence_epoch,
        );
    }
    (terminal_id, cols, rows, client_kind, viewer_presence_epoch)
}

pub(crate) fn detach_request_parts(
    terminal_id: String,
    client_kind: Option<String>,
    viewer_presence_epoch: Option<u64>,
    payload: Option<TerminalDetachPayload>,
) -> (String, Option<String>, Option<u64>) {
    if let Some(payload) = payload {
        return (
            payload.terminal_id,
            payload.client_kind,
            payload.viewer_presence_epoch,
        );
    }
    (terminal_id, client_kind, viewer_presence_epoch)
}

pub(crate) fn build_terminal_list_message(
    terminals: Vec<LocalTerminalSnapshot>,
) -> serde_json::Value {
    json!({
        "type": "terminal.list",
        "payload": {
            "terminals": terminals,
        }
    })
}

pub(crate) fn build_raw_terminal_ready_message(
    snapshot: &LocalTerminalSnapshot,
    viewer_presence_epoch: Option<u64>,
) -> serde_json::Value {
    json!({
        "type": "terminal.ready",
        "payload": {
            "terminal_id": snapshot.terminal_id,
            "device_id": snapshot.device_id,
            "title": snapshot.title,
            "source": snapshot.source,
            "shell": snapshot.shell,
            "cwd": snapshot.cwd,
            "state": snapshot.state,
            "cols": snapshot.cols,
            "rows": snapshot.rows,
            "created_at": snapshot.created_at,
            "closed_at": snapshot.closed_at,
            "latest_output_sequence": snapshot.latest_output_sequence,
            "history_truncated": snapshot.history_truncated,
            "viewer_presence_epoch": viewer_presence_epoch,
        },
    })
}

pub(crate) fn build_raw_terminal_snapshot_message(
    terminal_id: uuid::Uuid,
    snapshot: &LocalTerminalOutputSnapshot,
) -> serde_json::Value {
    json!({
        "type": "terminal.snapshot",
        "payload": {
            "terminal_id": terminal_id,
            "data_base64": BASE64.encode(&snapshot.bytes),
            "stream_sequence": snapshot.latest_sequence,
            "history_truncated": false,
        }
    })
}
