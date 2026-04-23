/// Shared terminal authority protocol negotiated by Desktop Server owned
/// runtimes. This is the long-term protocol for the shared terminal model.
pub const AUTHORITY_PROTOCOL_VERSION: u32 = 2;
pub const AUTHORITY_SYNC_MODE: &str = "state-cache-v2";

/// Legacy raw escape-stream fallback kept only for CLI compatibility during the
/// migration. Shared terminal surfaces should converge on the authority
/// protocol above.
pub const RAW_STREAM_PROTOCOL_VERSION: u32 = 1;
pub const RAW_STREAM_SYNC_MODE: &str = "raw-v1";

pub const TERMINAL_READY_EVENT_TYPE: &str = "terminal.ready";
pub const TERMINAL_STATE_SNAPSHOT_EVENT_TYPE: &str = "terminal.state.snapshot";
pub const TERMINAL_SCREEN_SNAPSHOT_EVENT_TYPE: &str = "terminal.screen.snapshot";
pub const TERMINAL_HISTORY_APPEND_EVENT_TYPE: &str = "terminal.history.append";
pub const TERMINAL_HISTORY_INVALIDATED_EVENT_TYPE: &str = "terminal.history.invalidated";
pub const TERMINAL_HISTORY_RANGE_RESPONSE_EVENT_TYPE: &str = "terminal.history.range.response";
pub const TERMINAL_HISTORY_RANGE_ERROR_EVENT_TYPE: &str = "terminal.history.range.error";
pub const TERMINAL_LAYOUT_CHANGED_EVENT_TYPE: &str = "terminal.layout.changed";
pub const TERMINAL_GEOMETRY_CHANGED_EVENT_TYPE: &str = "terminal.geometry.changed";
pub const TERMINAL_BUFFER_CHANGED_EVENT_TYPE: &str = "terminal.buffer.changed";
pub const TERMINAL_SCROLLBACK_TRIMMED_EVENT_TYPE: &str = "terminal.scrollback.trimmed";
pub const TERMINAL_OUTPUT_EVENT_TYPE: &str = "terminal.output";
pub const TERMINAL_SNAPSHOT_EVENT_TYPE: &str = "terminal.snapshot";
