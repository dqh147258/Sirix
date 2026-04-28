use super::{
    ApprovalChoice, ApprovalRequest, CliApprovalPrompt, ANSI_BOLD, ANSI_CYAN_BOLD, ANSI_DIM,
    ANSI_RESET,
};

impl CliApprovalPrompt {
    pub(super) fn overlay_lines(
        &self,
        request: &ApprovalRequest,
        choices: &[ApprovalChoice],
        selected_idx: usize,
    ) -> Vec<String> {
        let mut lines = Vec::new();
        lines.push(String::new());
        lines.push(format!(
            "  {ANSI_BOLD}{}{ANSI_RESET}",
            request.prompt_title()
        ));
        lines.push(String::new());

        if let Some(command) = request
            .shell_command
            .as_deref()
            .filter(|value| !value.is_empty())
        {
            lines.push("  Requested function: Shell command".to_string());
            lines.push(format!("  $ {command}"));
        } else {
            lines.push(format!(
                "  Requested function: {}",
                request.display_function_name()
            ));
            lines.push(format!(
                "  Function type: {}",
                request.display_function_type()
            ));
            lines.push(format!("  Capability key: {}", request.capability_key));
        }
        if let Some(kind) = request.approval_kind.as_deref() {
            lines.push(format!("  Kind: {kind}"));
        }
        if !request.agent_id.is_empty() || !request.model_id.is_empty() {
            lines.push(format!(
                "  Agent/model: {} · {}",
                request.agent_id, request.model_id
            ));
        }
        if let Some(cwd) = request.cwd.as_deref().filter(|value| !value.is_empty()) {
            lines.push(format!("  Cwd: {cwd}"));
        }
        if !request.shell_prefix_candidates.is_empty() {
            lines.push(format!(
                "  Shell prefix: {}",
                request.shell_prefix_candidates[0]
            ));
        }
        if !self.queue.is_empty() {
            lines.push(format!("  Queued approvals: {}", self.queue.len()));
        }

        lines.push(String::new());
        for (idx, choice) in choices.iter().enumerate() {
            let label = choice.codex_like_label(request);
            let numbered_label = format!("{}. {label}", idx + 1);
            if idx == selected_idx {
                lines.push(format!("  {ANSI_CYAN_BOLD}{numbered_label}{ANSI_RESET}"));
            } else {
                lines.push(format!("  {numbered_label}"));
            }
        }

        // Match Codex's key-hint language for the primary flow, while keeping
        // Sirix's raw-terminal detach shortcut explicit. Number shortcuts still
        // work as an accessibility fallback but are intentionally not styled as
        // the main UI because Codex's approval list is selection-based.
        lines.push(String::new());
        lines.push(format!(
            "  Use ↑/↓ or j/k · {ANSI_DIM}number/enter{ANSI_RESET} selects · {ANSI_DIM}esc{ANSI_RESET} denies · {ANSI_DIM}ctrl+c{ANSI_RESET} detaches"
        ));
        lines
    }

    pub(super) fn overlay_rendered_rows(&self, lines: &[String]) -> usize {
        let width = usize::from(self.terminal_width.max(1));
        lines
            .iter()
            .map(|line| {
                // Terminal soft-wrap happens by visible cells, while our strings
                // include ANSI styling. Count rows with ANSI escape sequences
                // removed so `clear_rendered` erases every visual row and does
                // not leave a stale second approval view behind after repaint.
                let visible_width = visible_cell_width(line);
                (visible_width.max(1) + width - 1) / width
            })
            .sum()
    }
}

impl ApprovalRequest {
    fn display_function_type(&self) -> &'static str {
        let raw = self.capability_key.trim();
        if raw.starts_with("builtin.") {
            return "Built-in tool";
        }
        if raw.starts_with("skill.") {
            return "Skill";
        }
        if raw.starts_with("mcp.") {
            return "MCP tool";
        }
        "Capability"
    }

    fn display_function_name(&self) -> String {
        let raw = self.capability_key.trim();
        raw.strip_prefix("builtin.")
            .or_else(|| raw.strip_prefix("skill."))
            .or_else(|| raw.strip_prefix("mcp."))
            .unwrap_or(raw)
            .to_string()
    }
}

fn visible_cell_width(line: &str) -> usize {
    let mut width = 0usize;
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' && chars.peek() == Some(&'[') {
            // Skip a CSI sequence such as `\x1b[1m` or `\x1b[0m`. The approval
            // overlay only emits simple SGR sequences today, but accepting any
            // ASCII final byte in 0x40..0x7e keeps this cross-terminal safe.
            chars.next();
            for next in chars.by_ref() {
                if ('@'..='~').contains(&next) {
                    break;
                }
            }
            continue;
        }
        width += if ch.is_ascii() { 1 } else { 2 };
    }
    width
}

impl ApprovalChoice {
    fn codex_like_label(self, request: &ApprovalRequest) -> String {
        if request.is_shell() {
            return self.codex_like_shell_label(request);
        }
        match (self.decision, self.scope) {
            ("allow", "once") => "Yes, grant these permissions for this turn".to_string(),
            ("deny", "once") => "No, continue without permissions".to_string(),
            ("allow", "session") => "Yes, grant these permissions for this session".to_string(),
            ("deny", "session") => "No, deny these permissions for this session".to_string(),
            ("allow", "workspace") => "Yes, grant these permissions for this workspace".to_string(),
            ("deny", "workspace") => "No, deny these permissions for this workspace".to_string(),
            ("allow", "global") => "Yes, grant these permissions globally".to_string(),
            ("deny", "global") => "No, deny these permissions globally".to_string(),
            (decision, scope) => format!("{decision} {scope}"),
        }
    }

    fn codex_like_shell_label(self, _request: &ApprovalRequest) -> String {
        match (self.decision, self.scope) {
            ("allow", "once") => "Yes, proceed".to_string(),
            ("deny", "once") => "No, continue without running it".to_string(),
            ("allow", scope @ ("session" | "workspace" | "global")) => {
                format!("Yes, choose a command prefix to allow for {scope}")
            }
            ("deny", scope @ ("session" | "workspace" | "global")) => {
                format!("No, choose a command prefix to deny for {scope}")
            }
            ("allow", scope) => format!("Yes, allow this command for {scope}"),
            ("deny", scope) => format!("No, deny this command for {scope}"),
            (decision, scope) => format!("{decision} {scope}"),
        }
    }
}
