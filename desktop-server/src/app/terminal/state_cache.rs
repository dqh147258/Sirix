use std::collections::VecDeque;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde::Serialize;
use serde_json::Value;
use tracing::info;
use uuid::Uuid;

use crate::app::terminal::vt_authority::{
    BufferKind, MainResizeStrategy, TerminalLine, VtAuthority, VtAuthoritySnapshot,
};
use crate::shared_terminal_protocol::AUTHORITY_SYNC_MODE;

const TERMINAL_STATE_CACHE_MAX_LINES: usize = 20_000;
const TERMINAL_HISTORY_PREVIEW_MAX_LINES: usize = 2_000;
pub const V2_SYNC_MODE: &str = AUTHORITY_SYNC_MODE;

#[derive(Debug, Clone, Serialize)]
pub struct TerminalStateSnapshotPayload {
    pub terminal_id: Uuid,
    pub active_buffer: &'static str,
    pub buffer_epoch: u64,
    pub layout_epoch: u64,
    pub main: MainBufferState,
    pub alt: AltBufferState,
}

#[derive(Debug, Clone, Serialize)]
pub struct MainBufferState {
    pub history_generation: u64,
    pub history_start_line: i64,
    pub history_end_line: i64,
    pub viewport_start_line: i64,
    pub viewport_end_line: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct AltBufferState {
    pub active: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalScreenSnapshotPayload {
    pub terminal_id: Uuid,
    pub buffer_kind: &'static str,
    pub buffer_epoch: u64,
    pub layout_epoch: u64,
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub screen_data_base64: String,
    pub screen_lines: Vec<TerminalLine>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalHistoryAppendPayload {
    pub terminal_id: Uuid,
    pub history_generation: u64,
    pub start_line: i64,
    pub end_line: i64,
    pub lines: Vec<TerminalLine>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalHistoryInvalidatedPayload {
    pub terminal_id: Uuid,
    pub history_generation: u64,
    pub history_start_line: i64,
    pub history_end_line: i64,
    pub start_line: i64,
    pub end_line: i64,
    pub lines: Vec<TerminalLine>,
    pub reason: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalLayoutChangedPayload {
    pub terminal_id: Uuid,
    pub layout_epoch: u64,
    pub rows: u16,
    pub cols: u16,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalBufferChangedPayload {
    pub terminal_id: Uuid,
    pub active_buffer: &'static str,
    pub buffer_epoch: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalScrollbackTrimmedPayload {
    pub terminal_id: Uuid,
    pub history_generation: u64,
    pub history_start_line: i64,
    pub history_end_line: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalHistoryRangeResponsePayload {
    pub request_id: String,
    pub terminal_id: Uuid,
    pub history_generation: u64,
    pub buffer_epoch: u64,
    pub layout_epoch: u64,
    pub start_line: i64,
    pub end_line: i64,
    pub lines: Vec<TerminalLine>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalHistoryRangeErrorPayload {
    pub request_id: String,
    pub terminal_id: Uuid,
    pub history_generation: u64,
    pub start_line: Option<i64>,
    pub end_line: Option<i64>,
    pub code: String,
    pub message: String,
    pub buffer_epoch: u64,
    pub layout_epoch: u64,
    pub history_start_line: i64,
    pub history_end_line: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalReadyV2Payload {
    pub terminal_id: Uuid,
    pub device_id: String,
    pub title: String,
    pub source: String,
    pub shell: String,
    pub cwd: String,
    pub state: String,
    pub session_state: String,
    pub cols: i32,
    pub rows: i32,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub closed_at: Option<chrono::DateTime<chrono::Utc>>,
    pub geometry_generation: u64,
    pub authority_source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub viewer_presence_epoch: Option<u64>,
    pub protocol_version: u32,
    pub sync_mode: &'static str,
}

#[derive(Debug, Clone, Copy)]
pub struct ResizeReplayMetadata {
    pub history_truncated: bool,
    pub replay_byte_len: usize,
    pub buffer_epoch: u64,
    pub layout_epoch: u64,
}

#[derive(Debug, Clone)]
pub struct TerminalOutboundEvent {
    pub event_type: &'static str,
    pub payload: Value,
}

impl TerminalOutboundEvent {
    pub fn new<T: Serialize>(event_type: &'static str, payload: &T) -> Self {
        Self {
            event_type,
            payload: serde_json::to_value(payload).expect("terminal payload must serialize"),
        }
    }

    pub fn into_message(self) -> Value {
        serde_json::json!({
            "type": self.event_type,
            "payload": self.payload,
        })
    }
}

pub struct TerminalSyncState {
    authority: VtAuthority,
    history_start_line: i64,
    main_lines: VecDeque<TerminalLine>,
    history_generation: u64,
    last_main_viewport_rows: usize,
    active_buffer: BufferKind,
    buffer_epoch: u64,
    layout_epoch: u64,
    current_rows: u16,
    current_cols: u16,
    current_cursor_row: u16,
    current_cursor_col: u16,
    current_screen_data: Vec<u8>,
    current_screen_lines: Vec<TerminalLine>,
}

impl TerminalSyncState {
    pub fn new(rows: u16, cols: u16) -> Self {
        let mut authority = VtAuthority::new(rows, cols, TERMINAL_STATE_CACHE_MAX_LINES);
        let snapshot = authority.snapshot();
        Self::from_snapshot(authority, snapshot)
    }

    pub fn apply_output(&mut self, terminal_id: Uuid, bytes: &[u8]) -> Vec<TerminalOutboundEvent> {
        let snapshot = self.authority.process_output(bytes);
        self.apply_snapshot(terminal_id, snapshot)
    }

    pub fn resize(
        &mut self,
        terminal_id: Uuid,
        rows: u16,
        cols: u16,
    ) -> Vec<TerminalOutboundEvent> {
        let snapshot = self.authority.resize(rows, cols);
        self.apply_snapshot(terminal_id, snapshot)
    }

    pub fn resize_with_replay(
        &mut self,
        terminal_id: Uuid,
        rows: u16,
        cols: u16,
        replay_bytes: Option<&[u8]>,
    ) -> Vec<TerminalOutboundEvent> {
        let metadata = ResizeReplayMetadata {
            history_truncated: false,
            replay_byte_len: replay_bytes.map_or(0, <[u8]>::len),
            buffer_epoch: self.buffer_epoch,
            layout_epoch: self.layout_epoch,
        };
        self.resize_with_replay_metadata(terminal_id, rows, cols, replay_bytes, metadata)
    }

    pub fn resize_with_replay_metadata(
        &mut self,
        terminal_id: Uuid,
        rows: u16,
        cols: u16,
        replay_bytes: Option<&[u8]>,
        replay_metadata: ResizeReplayMetadata,
    ) -> Vec<TerminalOutboundEvent> {
        let strategy = self.select_main_resize_strategy(replay_bytes, replay_metadata);
        info!(
            terminal_id = %terminal_id,
            active_buffer = %self.active_buffer.as_api_str(),
            rows,
            cols,
            canonical_main_line_count = self.main_lines.len(),
            current_screen_line_count = self.current_screen_lines.len(),
            history_truncated = replay_metadata.history_truncated,
            replay_byte_len = replay_metadata.replay_byte_len,
            replay_buffer_epoch = replay_metadata.buffer_epoch,
            replay_layout_epoch = replay_metadata.layout_epoch,
            strategy = match strategy {
                Some(MainResizeStrategy::ReplayBytes) => "main_replay_bytes",
                Some(MainResizeStrategy::CanonicalTranscript) => "main_canonical_transcript",
                None => "live_parser",
            },
            "[TERMINAL_HISTORY_TRACE] resize authority strategy selected"
        );
        let snapshot = match strategy {
            Some(MainResizeStrategy::ReplayBytes) => {
                self.authority
                    .resize_with_replay(rows, cols, replay_bytes.unwrap_or_default())
            }
            Some(MainResizeStrategy::CanonicalTranscript) => {
                let canonical_main_lines = self.main_lines.iter().cloned().collect::<Vec<_>>();
                self.authority
                    .resize_main_from_canonical_lines(rows, cols, &canonical_main_lines)
            }
            None => self.authority.resize(rows, cols),
        };
        self.apply_snapshot(terminal_id, snapshot)
    }

    pub fn bootstrap_events(
        &mut self,
        ready: TerminalReadyV2Payload,
    ) -> Vec<TerminalOutboundEvent> {
        let terminal_id = ready.terminal_id;
        let mut events = vec![
            TerminalOutboundEvent::new("terminal.ready", &ready),
            TerminalOutboundEvent::new(
                "terminal.state.snapshot",
                &self.state_snapshot_payload(terminal_id),
            ),
            TerminalOutboundEvent::new(
                "terminal.screen.snapshot",
                &self.screen_snapshot_payload(terminal_id),
            ),
        ];

        if let Some(preview) = self.bootstrap_history_preview_payload(terminal_id) {
            events.push(TerminalOutboundEvent::new(
                "terminal.history.invalidated",
                &preview,
            ));
        }

        events
    }

    pub fn history_range_response(
        &self,
        terminal_id: Uuid,
        request_id: String,
        start_line: i64,
        end_line: i64,
    ) -> TerminalOutboundEvent {
        let history_end_line = self.history_end_line();
        if start_line > end_line {
            return TerminalOutboundEvent::new(
                "terminal.history.range.error",
                &TerminalHistoryRangeErrorPayload {
                    request_id,
                    terminal_id,
                    history_generation: self.history_generation,
                    start_line: Some(start_line),
                    end_line: Some(end_line),
                    code: "HISTORY_RANGE_INVALID".to_string(),
                    message: "start_line must be <= end_line".to_string(),
                    buffer_epoch: self.buffer_epoch,
                    layout_epoch: self.layout_epoch,
                    history_start_line: self.history_start_line,
                    history_end_line,
                },
            );
        }
        if start_line == end_line {
            return TerminalOutboundEvent::new(
                "terminal.history.range.response",
                &TerminalHistoryRangeResponsePayload {
                    request_id,
                    terminal_id,
                    history_generation: self.history_generation,
                    buffer_epoch: self.buffer_epoch,
                    layout_epoch: self.layout_epoch,
                    start_line,
                    end_line,
                    lines: Vec::new(),
                },
            );
        }
        if start_line < self.history_start_line || end_line > history_end_line {
            return TerminalOutboundEvent::new(
                "terminal.history.range.error",
                &TerminalHistoryRangeErrorPayload {
                    request_id,
                    terminal_id,
                    history_generation: self.history_generation,
                    start_line: Some(start_line),
                    end_line: Some(end_line),
                    code: "HISTORY_RANGE_OUT_OF_BOUNDS".to_string(),
                    message: format!(
                        "requested range [{start_line}, {end_line}) is outside [{}, {})",
                        self.history_start_line, history_end_line
                    ),
                    buffer_epoch: self.buffer_epoch,
                    layout_epoch: self.layout_epoch,
                    history_start_line: self.history_start_line,
                    history_end_line,
                },
            );
        }

        let start_index = (start_line - self.history_start_line) as usize;
        let end_index = (end_line - self.history_start_line) as usize;
        let lines = self
            .main_lines
            .iter()
            .skip(start_index)
            .take(end_index - start_index)
            .cloned()
            .collect::<Vec<_>>();

        TerminalOutboundEvent::new(
            "terminal.history.range.response",
            &TerminalHistoryRangeResponsePayload {
                request_id,
                terminal_id,
                history_generation: self.history_generation,
                buffer_epoch: self.buffer_epoch,
                layout_epoch: self.layout_epoch,
                start_line,
                end_line,
                lines,
            },
        )
    }

    pub fn history_generation_mismatch(
        &self,
        terminal_id: Uuid,
        request_id: String,
        expected_history_generation: u64,
    ) -> TerminalOutboundEvent {
        TerminalOutboundEvent::new(
            "terminal.history.range.error",
            &TerminalHistoryRangeErrorPayload {
                request_id,
                terminal_id,
                history_generation: self.history_generation,
                start_line: None,
                end_line: None,
                code: "HISTORY_GENERATION_MISMATCH".to_string(),
                message: format!(
                    "requested history_generation={} but current history_generation={}",
                    expected_history_generation, self.history_generation
                ),
                buffer_epoch: self.buffer_epoch,
                layout_epoch: self.layout_epoch,
                history_start_line: self.history_start_line,
                history_end_line: self.history_end_line(),
            },
        )
    }

    pub fn current_history_generation(&self) -> u64 {
        self.history_generation
    }

    pub fn current_layout_epoch(&self) -> u64 {
        self.layout_epoch
    }

    pub fn current_buffer_epoch(&self) -> u64 {
        self.buffer_epoch
    }

    pub fn state_snapshot_payload(&self, terminal_id: Uuid) -> TerminalStateSnapshotPayload {
        let history_end_line = self.history_end_line();
        let viewport_rows = self.last_main_viewport_rows.min(self.main_lines.len()) as i64;
        let viewport_start_line = history_end_line.saturating_sub(viewport_rows);
        TerminalStateSnapshotPayload {
            terminal_id,
            active_buffer: self.active_buffer.as_api_str(),
            buffer_epoch: self.buffer_epoch,
            layout_epoch: self.layout_epoch,
            main: MainBufferState {
                history_generation: self.history_generation,
                history_start_line: self.history_start_line,
                history_end_line,
                viewport_start_line,
                viewport_end_line: history_end_line,
            },
            alt: AltBufferState {
                active: self.active_buffer == BufferKind::Alt,
            },
        }
    }

    pub fn screen_snapshot_payload(&self, terminal_id: Uuid) -> TerminalScreenSnapshotPayload {
        TerminalScreenSnapshotPayload {
            terminal_id,
            buffer_kind: self.active_buffer.as_api_str(),
            buffer_epoch: self.buffer_epoch,
            layout_epoch: self.layout_epoch,
            rows: self.current_rows,
            cols: self.current_cols,
            cursor_row: self.current_cursor_row,
            cursor_col: self.current_cursor_col,
            screen_data_base64: BASE64.encode(&self.current_screen_data),
            screen_lines: self.current_screen_lines.clone(),
        }
    }

    fn from_snapshot(authority: VtAuthority, snapshot: VtAuthoritySnapshot) -> Self {
        let last_main_viewport_rows = snapshot.screen_lines.len();
        Self {
            authority,
            history_start_line: 1,
            main_lines: VecDeque::from(snapshot.main_lines.clone()),
            history_generation: 0,
            last_main_viewport_rows,
            active_buffer: snapshot.active_buffer,
            buffer_epoch: snapshot.buffer_epoch,
            layout_epoch: snapshot.layout_epoch,
            current_rows: snapshot.rows,
            current_cols: snapshot.cols,
            current_cursor_row: snapshot.cursor_row,
            current_cursor_col: snapshot.cursor_col,
            current_screen_data: snapshot.formatted_screen,
            current_screen_lines: snapshot.screen_lines,
        }
    }

    fn apply_snapshot(
        &mut self,
        terminal_id: Uuid,
        snapshot: VtAuthoritySnapshot,
    ) -> Vec<TerminalOutboundEvent> {
        let old_history_start = self.history_start_line;
        let old_main_len = self.main_lines.len();
        let previous_main = self.main_lines.iter().cloned().collect::<Vec<_>>();
        let previous_history_end = self.history_end_line();

        self.active_buffer = snapshot.active_buffer;
        self.buffer_epoch = snapshot.buffer_epoch;
        self.layout_epoch = snapshot.layout_epoch;
        self.current_rows = snapshot.rows;
        self.current_cols = snapshot.cols;
        self.current_cursor_row = snapshot.cursor_row;
        self.current_cursor_col = snapshot.cursor_col;
        self.current_screen_data = snapshot.formatted_screen.clone();
        self.current_screen_lines = snapshot.screen_lines.clone();

        let mut appended_lines = Vec::new();
        let mut trimmed = false;
        let mut invalidated_preview = None;

        if snapshot.active_buffer == BufferKind::Main {
            self.last_main_viewport_rows = snapshot.screen_lines.len();
            let next_main_lines = if snapshot.clear_scrollback {
                snapshot.screen_lines.clone()
            } else {
                snapshot.main_lines.clone()
            };
            let layout_collapsed_to_viewport = snapshot.layout_changed
                && !snapshot.clear_scrollback
                && next_main_lines.len() <= snapshot.screen_lines.len()
                && old_main_len > snapshot.screen_lines.len();

            if layout_collapsed_to_viewport {
                // 已知遗留问题：当系统 Terminal 持续拖动窗口时，当前
                // state-cache 仍可能只能观测到 viewport 级别的数据，
                // 所以这里只能尽量保住 canonical history，不代表已经
                // 彻底解决 resize 过程中的历史丢失/错位。后续需要更
                // 完整的 grid/reflow 语义再继续处理。
                info!(
                    terminal_id = %terminal_id,
                    previous_main_len = old_main_len,
                    previous_history_start = old_history_start,
                    previous_history_end = previous_history_end,
                    snapshot_main_len = next_main_lines.len(),
                    snapshot_screen_len = snapshot.screen_lines.len(),
                    active_buffer = %snapshot.active_buffer.as_api_str(),
                    rows = snapshot.rows,
                    cols = snapshot.cols,
                    clear_scrollback = snapshot.clear_scrollback,
                    "[TERMINAL_HISTORY_TRACE] preserve canonical history across layout-only viewport shrink"
                );
            } else if snapshot.layout_changed {
                info!(
                    terminal_id = %terminal_id,
                    previous_main_len = old_main_len,
                    previous_history_start = old_history_start,
                    previous_history_end = previous_history_end,
                    snapshot_main_len = next_main_lines.len(),
                    snapshot_screen_len = snapshot.screen_lines.len(),
                    active_buffer = %snapshot.active_buffer.as_api_str(),
                    rows = snapshot.rows,
                    cols = snapshot.cols,
                    clear_scrollback = snapshot.clear_scrollback,
                    "[TERMINAL_HISTORY_TRACE] layout change invalidated authority history"
                );
                self.history_generation = self.history_generation.saturating_add(1);
                self.history_start_line = 0;
                self.main_lines = VecDeque::from(next_main_lines);
                if self.main_lines.len() > TERMINAL_STATE_CACHE_MAX_LINES {
                    let overflow = self.main_lines.len() - TERMINAL_STATE_CACHE_MAX_LINES;
                    for _ in 0..overflow {
                        let _ = self.main_lines.pop_front();
                    }
                    self.history_start_line = overflow as i64;
                }
                let history_end_line = self.history_end_line();
                let preview_end_line = history_end_line;
                let preview_start_line = preview_end_line
                    .saturating_sub(TERMINAL_HISTORY_PREVIEW_MAX_LINES as i64)
                    .max(self.history_start_line);
                let start_index = (preview_start_line - self.history_start_line) as usize;
                let preview_lines = self
                    .main_lines
                    .iter()
                    .skip(start_index)
                    .cloned()
                    .collect::<Vec<_>>();
                invalidated_preview = Some(TerminalHistoryInvalidatedPayload {
                    terminal_id,
                    history_generation: self.history_generation,
                    history_start_line: self.history_start_line,
                    history_end_line,
                    start_line: preview_start_line,
                    end_line: preview_end_line,
                    lines: preview_lines,
                    reason: "geometry_changed",
                });
            } else if snapshot.clear_scrollback {
                let removed = previous_main.len().saturating_sub(next_main_lines.len()) as i64;
                self.history_start_line = self.history_start_line.saturating_add(removed);
                trimmed = removed > 0;
                self.main_lines = VecDeque::from(next_main_lines);
            } else if starts_with(&next_main_lines, &previous_main)
                && next_main_lines.len() > previous_main.len()
            {
                appended_lines = next_main_lines[previous_main.len()..].to_vec();
                self.main_lines = VecDeque::from(next_main_lines);
            } else {
                if next_main_lines.len() < previous_main.len() {
                    let collapsed_to_viewport = next_main_lines.len()
                        <= snapshot.screen_lines.len()
                        && previous_main.len() > snapshot.screen_lines.len();
                    if collapsed_to_viewport {
                        // 参考 tmux 的 grid/history 思路：scrollback 应该被当作
                        // 持久主数据，而不是在 parser 某次瞬时只吐出“当前可视区”
                        // 时就直接把 canonical history 覆盖掉。
                        //
                        // 真实日志里最常见的问题就是：
                        // - resize / 重连后 VT parser 临时只剩几十行；
                        // - current screen 是对的，但 main history 被错误压缩；
                        // - Flutter 随后拿着这份缩水 history 做 rebuild，历史就丢了。
                        //
                        // 这里当“新 main_lines 退化到不超过当前 screen_lines，
                        // 且旧 canonical history 明显更长”时，视为 parser 的
                        // 临时退化，保留已有 canonical history，只同步当前 screen。
                        info!(
                            terminal_id = %terminal_id,
                            previous_main_len = previous_main.len(),
                            next_main_len = next_main_lines.len(),
                            screen_len = snapshot.screen_lines.len(),
                            history_generation = self.history_generation,
                            active_buffer = %snapshot.active_buffer.as_api_str(),
                            rows = snapshot.rows,
                            cols = snapshot.cols,
                            clear_scrollback = snapshot.clear_scrollback,
                            "[TERMINAL_HISTORY_TRACE] preserve canonical history on viewport-sized shrink"
                        );
                    } else {
                        info!(
                            terminal_id = %terminal_id,
                            previous_main_len = previous_main.len(),
                            next_main_len = next_main_lines.len(),
                            screen_len = snapshot.screen_lines.len(),
                            history_generation = self.history_generation,
                            active_buffer = %snapshot.active_buffer.as_api_str(),
                            rows = snapshot.rows,
                            cols = snapshot.cols,
                            clear_scrollback = snapshot.clear_scrollback,
                            "[TERMINAL_HISTORY_TRACE] main history shrank without explicit clear"
                        );
                        self.main_lines = VecDeque::from(next_main_lines);
                    }
                } else {
                    self.main_lines = VecDeque::from(next_main_lines);
                }
            }
            if self.main_lines.len() > TERMINAL_STATE_CACHE_MAX_LINES {
                let overflow = self.main_lines.len() - TERMINAL_STATE_CACHE_MAX_LINES;
                for _ in 0..overflow {
                    let _ = self.main_lines.pop_front();
                }
                self.history_start_line = self.history_start_line.saturating_add(overflow as i64);
                trimmed = true;
            }
        }

        let mut events = Vec::new();
        if let Some(payload) = invalidated_preview {
            events.push(TerminalOutboundEvent::new(
                "terminal.history.invalidated",
                &payload,
            ));
        }
        if !appended_lines.is_empty() {
            let start_line = old_history_start + old_main_len as i64;
            events.push(TerminalOutboundEvent::new(
                "terminal.history.append",
                &TerminalHistoryAppendPayload {
                    terminal_id,
                    history_generation: self.history_generation,
                    start_line,
                    end_line: start_line + appended_lines.len() as i64,
                    lines: appended_lines,
                },
            ));
        }

        if trimmed {
            events.push(TerminalOutboundEvent::new(
                "terminal.scrollback.trimmed",
                &TerminalScrollbackTrimmedPayload {
                    terminal_id,
                    history_generation: self.history_generation,
                    history_start_line: self.history_start_line,
                    history_end_line: self.history_end_line(),
                },
            ));
        }

        if snapshot.layout_changed {
            events.push(TerminalOutboundEvent::new(
                "terminal.layout.changed",
                &TerminalLayoutChangedPayload {
                    terminal_id,
                    layout_epoch: self.layout_epoch,
                    rows: self.current_rows,
                    cols: self.current_cols,
                },
            ));
        }

        if snapshot.buffer_changed {
            events.push(TerminalOutboundEvent::new(
                "terminal.buffer.changed",
                &TerminalBufferChangedPayload {
                    terminal_id,
                    active_buffer: self.active_buffer.as_api_str(),
                    buffer_epoch: self.buffer_epoch,
                },
            ));
        }

        // Authority mode must be able to render purely from canonical events,
        // not from the raw PTY byte stream. Emit the current state/screen on
        // every snapshot application so desktop-local / backend relay /
        // session transports all observe the same authoritative baseline and
        // prompt-like updates no longer depend on `terminal.output`.
        events.push(TerminalOutboundEvent::new(
            "terminal.state.snapshot",
            &self.state_snapshot_payload(terminal_id),
        ));
        events.push(TerminalOutboundEvent::new(
            "terminal.screen.snapshot",
            &TerminalScreenSnapshotPayload {
                terminal_id,
                buffer_kind: self.active_buffer.as_api_str(),
                buffer_epoch: self.buffer_epoch,
                layout_epoch: self.layout_epoch,
                rows: self.current_rows,
                cols: self.current_cols,
                cursor_row: self.current_cursor_row,
                cursor_col: self.current_cursor_col,
                screen_data_base64: BASE64.encode(&snapshot.formatted_screen),
                screen_lines: self.current_screen_lines.clone(),
            },
        ));

        events
    }

    fn history_end_line(&self) -> i64 {
        self.history_start_line + self.main_lines.len() as i64
    }

    fn bootstrap_history_preview_payload(
        &self,
        terminal_id: Uuid,
    ) -> Option<TerminalHistoryInvalidatedPayload> {
        if self.active_buffer != BufferKind::Main || self.main_lines.is_empty() {
            return None;
        }

        let history_end_line = self.history_end_line();
        let preview_start_line = history_end_line
            .saturating_sub(TERMINAL_HISTORY_PREVIEW_MAX_LINES as i64)
            .max(self.history_start_line);
        let start_index = (preview_start_line - self.history_start_line) as usize;
        let preview_lines = self
            .main_lines
            .iter()
            .skip(start_index)
            .cloned()
            .collect::<Vec<_>>();

        Some(TerminalHistoryInvalidatedPayload {
            terminal_id,
            history_generation: self.history_generation,
            history_start_line: self.history_start_line,
            history_end_line,
            start_line: preview_start_line,
            end_line: history_end_line,
            lines: preview_lines,
            reason: "bootstrap",
        })
    }

    fn select_main_resize_strategy(
        &self,
        replay_bytes: Option<&[u8]>,
        replay_metadata: ResizeReplayMetadata,
    ) -> Option<MainResizeStrategy> {
        if self.active_buffer != BufferKind::Main {
            return None;
        }

        let _ = replay_bytes;
        let _ = replay_metadata;

        // Shared-terminal resize now treats the canonical state cache as the
        // single source of truth. The raw replay ring remains available for
        // CLI raw fallback/debugging, but main-path reflow always rebuilds from
        // canonical lines so resize correctness no longer depends on byte
        // replay completeness or transport ordering.
        Some(MainResizeStrategy::CanonicalTranscript)
    }
}

fn starts_with(current: &[TerminalLine], previous: &[TerminalLine]) -> bool {
    previous.len() <= current.len()
        && current
            .iter()
            .take(previous.len())
            .zip(previous.iter())
            .all(|(left, right)| left == right)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clear_scrollback_advances_history_start_line() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 8);
        let _ = state.apply_output(terminal_id, b"one\r\ntwo\r\nthree\r\nfour\r\n");
        let before = state.state_snapshot_payload(terminal_id);
        assert!(before.main.history_end_line > before.main.history_start_line);

        let events = state.apply_output(terminal_id, b"\x1b[3J");
        assert!(events
            .iter()
            .any(|event| event.event_type == "terminal.scrollback.trimmed"));
        let after = state.state_snapshot_payload(terminal_id);
        assert!(after.main.history_start_line > before.main.history_start_line);
    }

    #[test]
    fn range_response_rejects_out_of_bounds() {
        let terminal_id = Uuid::new_v4();
        let state = TerminalSyncState::new(3, 8);
        let event = state.history_range_response(terminal_id, "req-1".to_string(), 0, 2);
        assert_eq!(event.event_type, "terminal.history.range.error");
    }

    #[test]
    fn bootstrap_events_include_history_preview_for_main_buffer() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 12);
        let _ = state.apply_output(terminal_id, b"alpha\r\nbeta\r\ngamma\r\ndelta\r\n");

        let events = state.bootstrap_events(TerminalReadyV2Payload {
            terminal_id,
            device_id: "device".to_string(),
            title: "Terminal".to_string(),
            source: "local_pty".to_string(),
            shell: "bash".to_string(),
            cwd: "/tmp".to_string(),
            state: "active".to_string(),
            session_state: "active".to_string(),
            cols: 12,
            rows: 3,
            created_at: chrono::Utc::now(),
            closed_at: None,
            geometry_generation: 0,
            authority_source: "system_terminal".to_string(),
            viewer_presence_epoch: Some(1),
            protocol_version: 2,
            sync_mode: V2_SYNC_MODE,
        });

        let preview = events
            .iter()
            .find(|event| event.event_type == "terminal.history.invalidated")
            .expect("bootstrap should include canonical history preview");
        assert_eq!(preview.payload["reason"], "bootstrap");
        assert!(preview
            .payload
            .get("lines")
            .and_then(|value| value.as_array())
            .is_some_and(|lines| !lines.is_empty()));
    }

    #[test]
    fn plain_output_still_emits_screen_snapshot_for_prompt_like_updates() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 12);

        let events = state.apply_output(terminal_id, b"prompt> ");
        let event_types = events
            .iter()
            .map(|event| event.event_type)
            .collect::<Vec<_>>();

        assert!(event_types.contains(&"terminal.state.snapshot"));
        assert!(event_types.contains(&"terminal.screen.snapshot"));

        let screen = state.screen_snapshot_payload(terminal_id);
        assert_eq!(screen.screen_lines[0].text, "prompt> ");
    }

    #[test]
    fn resize_with_replay_invalidates_using_full_history_window() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 12);
        let bytes = b"alpha bravo\r\nbeta gamma\r\ncharlie delta\r\necho foxtrot\r\n";
        let _ = state.apply_output(terminal_id, bytes);

        let events = state.resize_with_replay(terminal_id, 3, 8, Some(bytes));
        let invalidated = events
            .iter()
            .find(|event| event.event_type == "terminal.history.invalidated")
            .expect("layout resize should invalidate history");

        let history_end = invalidated
            .payload
            .get("history_end_line")
            .and_then(|value| value.as_i64())
            .unwrap_or_default();
        let history_start = invalidated
            .payload
            .get("history_start_line")
            .and_then(|value| value.as_i64())
            .unwrap_or_default();

        assert!(history_end - history_start > 3);
    }

    #[test]
    fn resize_with_truncated_replay_rebuilds_from_canonical_history() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 12);
        let bytes = b"alpha bravo\r\nbeta gamma\r\ncharlie delta\r\necho foxtrot\r\n";
        let _ = state.apply_output(terminal_id, bytes);
        let before = state.state_snapshot_payload(terminal_id);

        let events = state.resize_with_replay_metadata(
            terminal_id,
            3,
            8,
            Some(bytes),
            ResizeReplayMetadata {
                history_truncated: true,
                replay_byte_len: bytes.len(),
                buffer_epoch: state.buffer_epoch,
                layout_epoch: state.layout_epoch,
            },
        );
        let after = state.state_snapshot_payload(terminal_id);
        let invalidated = events
            .iter()
            .find(|event| event.event_type == "terminal.history.invalidated")
            .expect("canonical transcript resize should still invalidate history");

        let history_end = invalidated
            .payload
            .get("history_end_line")
            .and_then(|value| value.as_i64())
            .unwrap_or_default();
        let history_start = invalidated
            .payload
            .get("history_start_line")
            .and_then(|value| value.as_i64())
            .unwrap_or_default();

        assert!(
            after.main.history_end_line - after.main.history_start_line
                >= before.main.history_end_line - before.main.history_start_line
        );
        assert!(history_end - history_start > 3);
    }

    #[test]
    fn layout_resize_invalidation_preview_is_not_capped_to_tiny_window() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 24);
        let mut payload = Vec::new();
        for index in 0..320 {
            payload.extend_from_slice(format!("line-{index:03}\r\n").as_bytes());
        }
        let _ = state.apply_output(terminal_id, &payload);

        let events = state.resize_with_replay_metadata(
            terminal_id,
            4,
            18,
            Some(&payload),
            ResizeReplayMetadata {
                history_truncated: true,
                replay_byte_len: payload.len(),
                buffer_epoch: state.buffer_epoch,
                layout_epoch: state.layout_epoch,
            },
        );
        let invalidated = events
            .iter()
            .find(|event| event.event_type == "terminal.history.invalidated")
            .expect("layout resize should invalidate history");
        let preview_lines = invalidated
            .payload
            .get("lines")
            .and_then(|value| value.as_array())
            .map(|lines| lines.len())
            .unwrap_or_default();

        assert!(preview_lines > 200);
    }

    #[test]
    fn alt_resize_does_not_advance_main_history_generation() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 12);
        let _ = state.apply_output(terminal_id, b"one\r\ntwo\r\nthree\r\n");
        let before = state.state_snapshot_payload(terminal_id);

        let _ = state.apply_output(terminal_id, b"\x1b[?1049halt-screen");
        let _ = state.resize_with_replay_metadata(
            terminal_id,
            4,
            14,
            None,
            ResizeReplayMetadata {
                history_truncated: false,
                replay_byte_len: 0,
                buffer_epoch: state.buffer_epoch,
                layout_epoch: state.layout_epoch,
            },
        );
        let after = state.state_snapshot_payload(terminal_id);

        assert_eq!(
            after.main.history_generation,
            before.main.history_generation
        );
    }

    #[test]
    fn viewport_sized_shrink_preserves_canonical_history() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 24);
        let full_lines = (0..12)
            .map(|index| TerminalLine {
                text: format!("line-{index}"),
                wrapped: false,
                hard_break: true,
            })
            .collect::<Vec<_>>();
        state.main_lines = VecDeque::from(full_lines.clone());
        state.history_start_line = 1;
        state.current_screen_lines = full_lines[9..12].to_vec();
        state.current_rows = 3;
        state.current_cols = 24;
        let history_end_before = state.history_end_line();

        let shrink_snapshot = VtAuthoritySnapshot {
            active_buffer: BufferKind::Main,
            buffer_epoch: 0,
            layout_epoch: 0,
            rows: 3,
            cols: 24,
            cursor_row: 2,
            cursor_col: 0,
            screen_lines: full_lines[9..12].to_vec(),
            formatted_screen: Vec::new(),
            main_lines: full_lines[9..12].to_vec(),
            clear_scrollback: false,
            buffer_changed: false,
            layout_changed: false,
        };

        let events = state.apply_snapshot(terminal_id, shrink_snapshot);

        assert!(events.is_empty());
        assert_eq!(state.main_lines.len(), 12);
        assert_eq!(
            state
                .main_lines
                .front()
                .expect("canonical history should be kept")
                .text,
            "line-0"
        );
        assert_eq!(state.history_end_line(), history_end_before);
    }

    #[test]
    fn layout_changed_viewport_shrink_preserves_canonical_history() {
        let terminal_id = Uuid::new_v4();
        let mut state = TerminalSyncState::new(3, 24);
        let full_lines = (0..12)
            .map(|index| TerminalLine {
                text: format!("line-{index}"),
                wrapped: false,
                hard_break: true,
            })
            .collect::<Vec<_>>();
        state.main_lines = VecDeque::from(full_lines.clone());
        state.history_start_line = 1;
        state.current_screen_lines = full_lines[9..12].to_vec();
        state.current_rows = 3;
        state.current_cols = 24;
        let history_generation_before = state.history_generation;
        let history_end_before = state.history_end_line();

        let shrink_snapshot = VtAuthoritySnapshot {
            active_buffer: BufferKind::Main,
            buffer_epoch: 0,
            layout_epoch: 1,
            rows: 3,
            cols: 24,
            cursor_row: 2,
            cursor_col: 0,
            screen_lines: full_lines[9..12].to_vec(),
            formatted_screen: Vec::new(),
            main_lines: full_lines[9..12].to_vec(),
            clear_scrollback: false,
            buffer_changed: false,
            layout_changed: true,
        };

        let events = state.apply_snapshot(terminal_id, shrink_snapshot);

        assert!(events
            .iter()
            .all(|event| event.event_type != "terminal.history.invalidated"));
        assert_eq!(state.main_lines.len(), 12);
        assert_eq!(state.history_generation, history_generation_before);
        assert_eq!(state.history_end_line(), history_end_before);
    }
}
