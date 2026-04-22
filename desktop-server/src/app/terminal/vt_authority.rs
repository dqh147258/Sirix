use serde::Serialize;

const CSI_CLEAR_SCREEN: &[u8] = b"\x1b[2J";
const CSI_CLEAR_SCROLLBACK: &[u8] = b"\x1b[3J";
const CSI_ALT_ENTER: &[u8] = b"\x1b[?1049h";
const CSI_ALT_EXIT: &[u8] = b"\x1b[?1049l";
const ESC_HARD_RESET: &[u8] = b"\x1bc";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BufferKind {
    Main,
    Alt,
}

impl BufferKind {
    pub fn as_api_str(self) -> &'static str {
        match self {
            Self::Main => "main",
            Self::Alt => "alt",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalLine {
    pub text: String,
    pub wrapped: bool,
    pub hard_break: bool,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ControlFlags {
    pub clear_screen: bool,
    pub clear_scrollback: bool,
    pub hard_reset: bool,
    pub alt_enter: bool,
    pub alt_exit: bool,
}

#[derive(Debug, Clone)]
pub struct VtAuthoritySnapshot {
    pub active_buffer: BufferKind,
    pub buffer_epoch: u64,
    pub layout_epoch: u64,
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub screen_lines: Vec<TerminalLine>,
    pub formatted_screen: Vec<u8>,
    pub main_lines: Vec<TerminalLine>,
    pub clear_scrollback: bool,
    pub buffer_changed: bool,
    pub layout_changed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MainResizeStrategy {
    ReplayBytes,
    CanonicalTranscript,
}

pub struct VtAuthority {
    parser: vt100::Parser,
    scrollback_len: usize,
    last_active_buffer: BufferKind,
    buffer_epoch: u64,
    layout_epoch: u64,
    cached_main_lines: Vec<TerminalLine>,
}

impl VtAuthority {
    pub fn new(rows: u16, cols: u16, scrollback_len: usize) -> Self {
        let parser = vt100::Parser::new(rows, cols, scrollback_len);
        Self {
            parser,
            scrollback_len,
            last_active_buffer: BufferKind::Main,
            buffer_epoch: 0,
            layout_epoch: 0,
            cached_main_lines: blank_lines(rows),
        }
    }

    pub fn process_output(&mut self, bytes: &[u8]) -> VtAuthoritySnapshot {
        let flags = detect_control_flags(bytes);
        self.parser.process(bytes);
        self.snapshot_with_flags(flags, false)
    }

    pub fn resize(&mut self, rows: u16, cols: u16) -> VtAuthoritySnapshot {
        self.parser.screen_mut().set_size(rows, cols);
        self.layout_epoch = self.layout_epoch.saturating_add(1);
        self.snapshot_with_flags(ControlFlags::default(), true)
    }

    pub fn resize_with_replay(
        &mut self,
        rows: u16,
        cols: u16,
        replay_bytes: &[u8],
    ) -> VtAuthoritySnapshot {
        // vt100 当前 parser 在 set_size() 后无法稳定保留完整 scrollback：
        // 当系统终端拖动宽度时，它经常只剩“可视区行数”可供读取，导致
        // Flutter 端拿到的 history invalidated preview 永远只有几十行。
        //
        // 这里改成基于 replay buffer 重新回放完整输出流，再在新的 rows/cols
        // 下重建 parser 状态。这样可让当前宽度对应的 main buffer / scrollback
        // 一次性按新几何重新铺开，避免 resize 后历史突然缩水。
        let mut parser = vt100::Parser::new(rows, cols, self.scrollback_len);
        if !replay_bytes.is_empty() {
            parser.process(replay_bytes);
        }
        self.parser = parser;
        self.layout_epoch = self.layout_epoch.saturating_add(1);
        self.snapshot_with_flags(ControlFlags::default(), true)
    }

    pub fn resize_main_from_canonical_lines(
        &mut self,
        rows: u16,
        cols: u16,
        canonical_lines: &[TerminalLine],
    ) -> VtAuthoritySnapshot {
        // 当 replay buffer 已截断时，不能再用不完整的输出流重建 parser，
        // 否则新的 authority 会被压缩成“仅剩当前可视区”的退化状态。
        //
        // 这里改为使用 state-cache 已经守住的 canonical main_lines 重新构造
        // transcript，并在新几何下重建一个新的持久 parser。这样虽然会丢失
        // ANSI 样式等富文本细节，但能守住：
        // 1. scrollback 行序与换行稳定；
        // 2. 后续增量 output 仍然基于新的持久 parser 继续处理；
        // 3. truncated replay 不再污染 canonical history。
        //
        // 已知遗留问题（暂时搁置，后续单独处理）：
        // - 当用户持续拖动列宽时，历史重建仍可能出现部分丢失或错乱。
        //   根因是当前只能用 canonical text transcript 近似重建，而不能完整
        //   保留真实终端 parser 的样式/换行上下文；本次提交先保证“不要被
        //   truncated replay 直接压缩成一屏历史”，不在这里继续扩大战线。
        let transcript = canonical_lines_to_transcript(canonical_lines);
        let mut parser = vt100::Parser::new(rows, cols, self.scrollback_len);
        if !transcript.is_empty() {
            parser.process(&transcript);
        }
        self.parser = parser;
        self.layout_epoch = self.layout_epoch.saturating_add(1);
        self.snapshot_with_flags(ControlFlags::default(), true)
    }

    pub fn snapshot(&mut self) -> VtAuthoritySnapshot {
        self.snapshot_with_flags(ControlFlags::default(), false)
    }

    fn snapshot_with_flags(
        &mut self,
        flags: ControlFlags,
        layout_changed: bool,
    ) -> VtAuthoritySnapshot {
        let screen = self.parser.screen().clone();
        let active_buffer = if screen.alternate_screen() {
            BufferKind::Alt
        } else {
            BufferKind::Main
        };
        let buffer_changed = active_buffer != self.last_active_buffer
            || flags.clear_screen
            || flags.hard_reset
            || flags.alt_enter
            || flags.alt_exit;
        if buffer_changed {
            self.buffer_epoch = self.buffer_epoch.saturating_add(1);
        }
        self.last_active_buffer = active_buffer;

        let (rows, cols) = screen.size();
        let cursor = screen.cursor_position();
        let screen_lines = collect_screen_lines(&screen, rows, cols);
        let formatted_screen = screen.state_formatted();
        let main_lines = if active_buffer == BufferKind::Main {
            let lines = collect_main_lines(&screen, rows, cols);
            self.cached_main_lines = lines.clone();
            lines
        } else {
            self.cached_main_lines.clone()
        };

        VtAuthoritySnapshot {
            active_buffer,
            buffer_epoch: self.buffer_epoch,
            layout_epoch: self.layout_epoch,
            rows,
            cols,
            cursor_row: cursor.0,
            cursor_col: cursor.1,
            screen_lines,
            formatted_screen,
            main_lines,
            clear_scrollback: flags.clear_scrollback,
            buffer_changed,
            layout_changed,
        }
    }
}

fn blank_lines(rows: u16) -> Vec<TerminalLine> {
    (0..rows)
        .map(|_| TerminalLine {
            text: String::new(),
            wrapped: false,
            hard_break: true,
        })
        .collect()
}

fn canonical_lines_to_transcript(lines: &[TerminalLine]) -> Vec<u8> {
    let mut transcript = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        transcript.extend_from_slice(line.text.as_bytes());
        if line.hard_break && index + 1 < lines.len() {
            // 使用 CRLF 让重建后的 parser 在下一物理行起始列继续排版，
            // 尽量贴近真实 PTY 的“换行并回到第 0 列”行为。
            transcript.extend_from_slice(b"\r\n");
        }
    }
    transcript
}

fn collect_main_lines(screen: &vt100::Screen, rows: u16, cols: u16) -> Vec<TerminalLine> {
    let mut max_probe = screen.clone();
    max_probe.set_scrollback(usize::MAX);
    let max_scrollback = max_probe.scrollback();

    let mut lines = Vec::with_capacity(max_scrollback.saturating_add(rows as usize));
    let mut previous_wrapped = false;

    // vt100 公开 API 只允许按“当前可视窗口”读取 scrollback，因此这里通过
    // 逐步下移窗口并抽取顶部行，稳定重建完整的 main buffer 物理行序列。
    for offset in (1..=max_scrollback).rev() {
        let mut probe = screen.clone();
        probe.set_scrollback(offset);
        let text = probe.rows(0, cols).next().unwrap_or_default();
        let wraps_next = probe.row_wrapped(0);
        lines.push(TerminalLine {
            text,
            wrapped: previous_wrapped,
            hard_break: !wraps_next,
        });
        previous_wrapped = wraps_next;
    }

    let mut visible = screen.clone();
    visible.set_scrollback(0);
    for (index, text) in visible.rows(0, cols).enumerate() {
        let row = index as u16;
        let wraps_next = visible.row_wrapped(row);
        lines.push(TerminalLine {
            text,
            wrapped: previous_wrapped,
            hard_break: !wraps_next,
        });
        previous_wrapped = wraps_next;
    }

    lines
}

fn collect_screen_lines(screen: &vt100::Screen, rows: u16, cols: u16) -> Vec<TerminalLine> {
    let mut visible = screen.clone();
    visible.set_scrollback(0);

    let mut lines = Vec::with_capacity(rows as usize);
    let mut previous_wrapped = false;
    for (index, text) in visible.rows(0, cols).enumerate() {
        let row = index as u16;
        let wraps_next = visible.row_wrapped(row);
        lines.push(TerminalLine {
            text,
            wrapped: previous_wrapped,
            hard_break: !wraps_next,
        });
        previous_wrapped = wraps_next;
    }
    while lines.len() < rows as usize {
        lines.push(TerminalLine {
            text: String::new(),
            wrapped: previous_wrapped,
            hard_break: true,
        });
        previous_wrapped = false;
    }
    lines
}

fn detect_control_flags(bytes: &[u8]) -> ControlFlags {
    ControlFlags {
        clear_screen: contains_bytes(bytes, CSI_CLEAR_SCREEN),
        clear_scrollback: contains_bytes(bytes, CSI_CLEAR_SCROLLBACK),
        hard_reset: contains_bytes(bytes, ESC_HARD_RESET),
        alt_enter: contains_bytes(bytes, CSI_ALT_ENTER),
        alt_exit: contains_bytes(bytes, CSI_ALT_EXIT),
    }
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_clear_and_alt_sequences() {
        let flags = detect_control_flags(b"\x1b[2J\x1b[3J\x1b[?1049h\x1b[?1049l\x1bc");
        assert!(flags.clear_screen);
        assert!(flags.clear_scrollback);
        assert!(flags.alt_enter);
        assert!(flags.alt_exit);
        assert!(flags.hard_reset);
    }

    #[test]
    fn collects_scrollback_rows_in_oldest_first_order() {
        let mut authority = VtAuthority::new(3, 6, 32);
        authority.process_output(b"one\r\ntwo\r\nthree\r\nfour\r\n");
        let snapshot = authority.snapshot();
        let texts: Vec<&str> = snapshot
            .main_lines
            .iter()
            .map(|line| line.text.as_str())
            .collect();
        assert!(texts.starts_with(&["one", "two"]));
        assert!(texts.iter().any(|line| *line == "four"));
    }

    #[test]
    fn resize_with_replay_preserves_scrollback_history() {
        let bytes = b"alpha bravo\r\nbeta gamma\r\ncharlie delta\r\necho foxtrot\r\n";
        let mut authority = VtAuthority::new(3, 12, 64);
        authority.process_output(bytes);

        let resized = authority.resize_with_replay(3, 8, bytes);
        let texts: Vec<&str> = resized
            .main_lines
            .iter()
            .map(|line| line.text.as_str())
            .collect();

        assert!(texts.iter().any(|line| line.contains("alpha")));
        assert!(texts.iter().any(|line| line.contains("echo")));
        assert!(resized.main_lines.len() > 3);
    }

    #[test]
    fn resize_main_from_canonical_lines_preserves_scrollback_history() {
        let bytes = b"alpha bravo\r\nbeta gamma\r\ncharlie delta\r\necho foxtrot\r\n";
        let mut authority = VtAuthority::new(3, 12, 64);
        let initial = authority.process_output(bytes);

        let resized = authority.resize_main_from_canonical_lines(3, 8, &initial.main_lines);
        let texts: Vec<&str> = resized
            .main_lines
            .iter()
            .map(|line| line.text.as_str())
            .collect();

        assert!(texts.iter().any(|line| line.contains("alpha")));
        assert!(texts.iter().any(|line| line.contains("echo")));
        assert!(resized.main_lines.len() > 3);
    }
}
