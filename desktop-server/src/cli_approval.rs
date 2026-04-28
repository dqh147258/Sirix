use std::collections::VecDeque;
use std::fmt;
use std::io::Write;

use anyhow::Context;

use crate::cli_support::local_http_url;

const ANSI_RESET: &str = "\x1b[0m";
const ANSI_BOLD: &str = "\x1b[1m";
const ANSI_DIM: &str = "\x1b[2m";
const ANSI_RED: &str = "\x1b[31m";
const ANSI_CYAN_BOLD: &str = "\x1b[1m\x1b[36m";
const ANSI_SHOW_CURSOR: &str = "\x1b[?25h";
const ANSI_CLEAR_LINE: &str = "\x1b[2K";

/// Raw terminal approval UI shared by `sirix` and `sirix-terminal`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ApprovalInputAction {
    Consumed,
    DetachRequested,
}

pub(crate) struct CliApprovalPrompt {
    port: u16,
    client_name: &'static str,
    http: reqwest::Client,
    active: Option<ApprovalRequest>,
    queue: VecDeque<ApprovalRequest>,
    prefix_selection: Option<PendingPrefixSelection>,
    selected_idx: usize,
    terminal_width: u16,
    last_rendered_row_count: usize,
}

impl CliApprovalPrompt {
    pub(crate) fn new(port: u16, client_name: &'static str) -> Self {
        Self {
            port,
            client_name,
            http: reqwest::Client::new(),
            active: None,
            queue: VecDeque::new(),
            prefix_selection: None,
            selected_idx: 0,
            terminal_width: 120,
            last_rendered_row_count: 0,
        }
    }

    pub(crate) fn has_pending(&self) -> bool {
        self.active.is_some()
    }

    pub(crate) fn set_terminal_width(&mut self, width: u16) {
        // Clear by visual rows, so soft-wrapped Codex-style labels do not leave stale panes.
        self.terminal_width = width.max(1);
    }

    pub(crate) fn handle_request_event<W: Write>(
        &mut self,
        stdout: &mut W,
        body: &serde_json::Value,
    ) -> anyhow::Result<()> {
        let Some(request) = ApprovalRequest::from_payload(body) else {
            return Ok(());
        };
        if self.contains_request(&request) {
            return Ok(());
        }
        if self.active.is_none() {
            self.active = Some(request);
            self.selected_idx = 0;
            self.render_active(stdout)?;
        } else {
            self.queue.push_back(request);
            // Repaint the menu; append-only queue notices are easily corrupted by PTY frames.
            self.render_active(stdout)?;
        }
        Ok(())
    }

    pub(crate) fn handle_resolved_event<W: Write>(
        &mut self,
        stdout: &mut W,
        body: &serde_json::Value,
    ) -> anyhow::Result<()> {
        let request_id = body
            .get("request_id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();
        let ai_session_id = body
            .get("ai_session_id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();
        let agent_id = body
            .get("agent_id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();
        let capability_key = body
            .get("capability_key")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();

        let queue_len_before = self.queue.len();
        self.queue.retain(|request| {
            !request.matches_resolution(request_id, ai_session_id, agent_id, capability_key)
        });
        let queue_changed = self.queue.len() != queue_len_before;
        if self.active.as_ref().is_some_and(|request| {
            request.matches_resolution(request_id, ai_session_id, agent_id, capability_key)
        }) {
            self.clear_rendered(stdout)?;
            let decision = body
                .get("decision")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("resolved");
            writeln!(
                stdout,
                "\r\n{ANSI_SHOW_CURSOR}[{name}] approval {decision}; continuing.",
                name = self.client_name,
            )
            .context("failed to write approval resolution notice")?;
            self.finish_active_request(stdout)?;
        } else if queue_changed && self.active.is_some() {
            // Another endpoint resolved a queued request; keep the queue count honest.
            self.render_active(stdout)?;
        }
        stdout.flush().ok();
        Ok(())
    }

    pub(crate) async fn handle_stdin_bytes<W: Write>(
        &mut self,
        stdout: &mut W,
        bytes: &[u8],
    ) -> anyhow::Result<ApprovalInputAction> {
        if self.input_requests_detach(bytes) {
            self.clear_rendered(stdout)?;
            writeln!(
                stdout,
                "\r\n{ANSI_SHOW_CURSOR}{ANSI_DIM}[{name}] approval left pending; detaching local terminal. Resolve it from another endpoint or reconnect.{ANSI_RESET}",
                name = self.client_name,
            )
            .context("failed to write approval detach notice")?;
            stdout.flush().ok();
            return Ok(ApprovalInputAction::DetachRequested);
        }

        if self.apply_navigation_input(stdout, bytes)? {
            return Ok(ApprovalInputAction::Consumed);
        }

        if self.prefix_selection.is_some() {
            return self.handle_prefix_selection_input(stdout, bytes).await;
        }

        let Some(choice) = self.choice_from_input(bytes) else {
            // Keep the Codex-style selection surface stable on unrelated keys.
            write!(stdout, "\x07").context("failed to write approval input bell")?;
            return Ok(ApprovalInputAction::Consumed);
        };
        let Some(request) = self.active.clone() else {
            return Ok(ApprovalInputAction::Consumed);
        };

        if request.requires_prefix_selection(&choice) {
            self.open_prefix_selection(request, choice, stdout)?;
            return Ok(ApprovalInputAction::Consumed);
        }

        let outcome_label = format!("{} {}", choice.decision, choice.scope);
        // Clear the local pane before submitting; backend state remains shared until resolve wins.
        self.clear_rendered(stdout)?;
        match self.resolve_request(&request, &choice, None).await {
            Ok(()) => {
                writeln!(
                    stdout,
                    "\r\n{ANSI_SHOW_CURSOR}[{name}] submitted approval: {outcome_label}.",
                    name = self.client_name,
                )
                .context("failed to write approval submit notice")?;
                self.finish_active_request(stdout)?;
            }
            Err(error) => {
                writeln!(
                    stdout,
                    "\r\n{ANSI_SHOW_CURSOR}{ANSI_RED}[{name}] failed to submit approval: {error}{ANSI_RESET}",
                    name = self.client_name,
                )
                .context("failed to write approval error")?;
                if is_stale_resolution_error(&error) {
                    // Another endpoint likely won the resolve race; clear only this stale UI.
                    writeln!(
                        stdout,
                        "{ANSI_DIM}[{name}] cleared stale local approval prompt; reconnect or use another endpoint if approval is still required.{ANSI_RESET}",
                        name = self.client_name,
                    )
                    .context("failed to write approval stale hint")?;
                    self.finish_active_request(stdout)?;
                } else {
                    writeln!(
                        stdout,
                        "{ANSI_DIM}[{name}] approval is still pending; choose again or wait for another endpoint to resolve it.{ANSI_RESET}",
                        name = self.client_name,
                    )
                    .context("failed to write approval retry hint")?;
                    self.render_active(stdout)?;
                }
            }
        }
        stdout.flush().ok();
        Ok(ApprovalInputAction::Consumed)
    }

    fn contains_request(&self, request: &ApprovalRequest) -> bool {
        // `request_id` is the approval identity. A shell command may legitimately
        // produce multiple sequential approvals with the same capability key
        // (for example capability authorization followed by command/prefix
        // approval), so capability-only de-duplication would incorrectly skip
        // the second gate and let execution continue too early.
        self.active
            .as_ref()
            .is_some_and(|active| active.conflicts_with(request))
            || self
                .queue
                .iter()
                .any(|queued| queued.conflicts_with(request))
    }

    fn render_active<W: Write>(&mut self, stdout: &mut W) -> anyhow::Result<()> {
        let lines = if let Some(selection) = self.prefix_selection.as_ref() {
            if self.selected_idx >= selection.prefixes.len() {
                self.selected_idx = 0;
            }
            selection.overlay_lines(self.selected_idx)
        } else {
            let Some(request) = self.active.as_ref() else {
                return Ok(());
            };
            let choices = request.choices();
            if self.selected_idx >= choices.len() {
                self.selected_idx = 0;
            }
            let selected_idx = self.selected_idx;
            self.overlay_lines(request, &choices, selected_idx)
        };

        // Match Codex bottom-pane behavior: repaint only the approval rows, never the screen.
        self.clear_rendered(stdout)?;
        for line in &lines {
            write_overlay_line(stdout, format_args!("{line}"))?;
        }
        self.last_rendered_row_count = self.overlay_rendered_rows(&lines);
        stdout.flush().ok();
        Ok(())
    }

    fn clear_rendered<W: Write>(&mut self, stdout: &mut W) -> anyhow::Result<()> {
        for _ in 0..self.last_rendered_row_count {
            write!(stdout, "\x1b[1A\r{ANSI_CLEAR_LINE}")
                .context("failed to clear approval overlay line")?;
        }
        if self.last_rendered_row_count > 0 {
            write!(stdout, "\r").context("failed to reset approval overlay cursor")?;
        }
        self.last_rendered_row_count = 0;
        Ok(())
    }

    fn apply_navigation_input<W: Write>(
        &mut self,
        stdout: &mut W,
        bytes: &[u8],
    ) -> anyhow::Result<bool> {
        let choices_len = if let Some(selection) = self.prefix_selection.as_ref() {
            selection.prefixes.len()
        } else {
            let Some(request) = self.active.as_ref() else {
                return Ok(false);
            };
            request.choices().len()
        };
        if choices_len == 0 {
            return Ok(false);
        }

        let delta = match bytes {
            b"\x1b[A" | b"k" => Some(-1isize),
            b"\x1b[B" | b"j" => Some(1isize),
            _ => None,
        };
        let Some(delta) = delta else {
            return Ok(false);
        };

        if delta < 0 {
            self.selected_idx = self
                .selected_idx
                .checked_sub(1)
                .unwrap_or(choices_len.saturating_sub(1));
        } else {
            self.selected_idx = (self.selected_idx + 1) % choices_len;
        }
        self.render_active(stdout)?;
        Ok(true)
    }

    fn choice_from_input(&self, bytes: &[u8]) -> Option<ApprovalChoice> {
        let request = self.active.as_ref()?;
        let first = bytes.first().copied()?;
        if bytes == b"\r" || bytes == b"\n" {
            return request.choices().get(self.selected_idx).copied();
        }
        if bytes == b"\x1b" {
            return Some(ApprovalChoice {
                decision: "deny",
                scope: "once",
            });
        }
        if let Some(choice) = self.choice_from_shortcut(bytes, request) {
            return Some(choice);
        }
        let digit = char::from(first).to_digit(10)?;
        if digit == 0 {
            return None;
        }
        let idx = usize::try_from(digit).ok()?.checked_sub(1)?;
        request.choices().get(idx).copied()
    }

    fn choice_from_shortcut(
        &self,
        bytes: &[u8],
        request: &ApprovalRequest,
    ) -> Option<ApprovalChoice> {
        let first = bytes.first().copied()?.to_ascii_lowercase();
        let choices = request.choices();
        match first {
            b'y' => choices.iter().copied().find(|choice| {
                choice.decision == "allow" && matches!(choice.scope, "once" | "session")
            }),
            b'a' => choices
                .iter()
                .copied()
                .find(|choice| choice.decision == "allow" && choice.scope == "session")
                .or_else(|| {
                    choices
                        .iter()
                        .copied()
                        .find(|choice| choice.decision == "allow")
                }),
            b'p' => choices
                .iter()
                .copied()
                .find(|choice| choice.decision == "allow" && choice.scope == "workspace"),
            b'g' => choices
                .iter()
                .copied()
                .find(|choice| choice.decision == "allow" && choice.scope == "global"),
            b'n' | b'd' => choices
                .iter()
                .copied()
                .find(|choice| choice.decision == "deny"),
            _ => None,
        }
    }

    fn input_requests_detach(&self, bytes: &[u8]) -> bool {
        // Ctrl-C detaches locally without resolving the shared Desktop/Mobile/CLI request.
        bytes.first().copied() == Some(0x03)
    }

    fn open_prefix_selection<W: Write>(
        &mut self,
        request: ApprovalRequest,
        choice: ApprovalChoice,
        stdout: &mut W,
    ) -> anyhow::Result<()> {
        // Persistent shell approvals are intentionally two-stage in every
        // surface: first choose the authorization scope, then choose the exact
        // command prefix that will be remembered. Auto-picking the first prefix
        // would make the command continue before the user has completed the
        // second gate, which is the bug this state explicitly prevents.
        self.prefix_selection = Some(PendingPrefixSelection {
            prefixes: request.shell_prefix_candidates.clone(),
            request,
            choice,
        });
        self.selected_idx = 0;
        self.render_active(stdout)
    }

    async fn handle_prefix_selection_input<W: Write>(
        &mut self,
        stdout: &mut W,
        bytes: &[u8],
    ) -> anyhow::Result<ApprovalInputAction> {
        let Some(selection) = self.prefix_selection.clone() else {
            return Ok(ApprovalInputAction::Consumed);
        };

        let selected_prefix = if bytes == b"\r" || bytes == b"\n" {
            selection.prefixes.get(self.selected_idx).cloned()
        } else {
            let Some(first) = bytes.first().copied() else {
                return Ok(ApprovalInputAction::Consumed);
            };
            let Some(digit) = char::from(first).to_digit(10) else {
                write!(stdout, "\x07").context("failed to write approval input bell")?;
                return Ok(ApprovalInputAction::Consumed);
            };
            let Some(idx) = usize::try_from(digit)
                .ok()
                .and_then(|value| value.checked_sub(1))
            else {
                write!(stdout, "\x07").context("failed to write approval input bell")?;
                return Ok(ApprovalInputAction::Consumed);
            };
            selection.prefixes.get(idx).cloned()
        };

        let Some(selected_prefix) = selected_prefix else {
            write!(stdout, "\x07").context("failed to write approval input bell")?;
            return Ok(ApprovalInputAction::Consumed);
        };

        let outcome_label = format!(
            "{} {} ({selected_prefix})",
            selection.choice.decision, selection.choice.scope
        );
        self.clear_rendered(stdout)?;
        match self
            .resolve_request(
                &selection.request,
                &selection.choice,
                Some(selected_prefix.as_str()),
            )
            .await
        {
            Ok(()) => {
                writeln!(
                    stdout,
                    "\r\n{ANSI_SHOW_CURSOR}[{name}] submitted approval: {outcome_label}.",
                    name = self.client_name,
                )
                .context("failed to write approval submit notice")?;
                self.finish_active_request(stdout)?;
            }
            Err(error) => {
                writeln!(
                    stdout,
                    "\r\n{ANSI_SHOW_CURSOR}{ANSI_RED}[{name}] failed to submit approval: {error}{ANSI_RESET}",
                    name = self.client_name,
                )
                .context("failed to write approval error")?;
                if is_stale_resolution_error(&error) {
                    writeln!(
                        stdout,
                        "{ANSI_DIM}[{name}] cleared stale local approval prompt; reconnect or use another endpoint if approval is still required.{ANSI_RESET}",
                        name = self.client_name,
                    )
                    .context("failed to write approval stale hint")?;
                    self.finish_active_request(stdout)?;
                } else {
                    writeln!(
                        stdout,
                        "{ANSI_DIM}[{name}] approval is still pending; choose again or wait for another endpoint to resolve it.{ANSI_RESET}",
                        name = self.client_name,
                    )
                    .context("failed to write approval retry hint")?;
                    self.render_active(stdout)?;
                }
            }
        }
        stdout.flush().ok();
        Ok(ApprovalInputAction::Consumed)
    }

    fn finish_active_request<W: Write>(&mut self, stdout: &mut W) -> anyhow::Result<()> {
        self.prefix_selection = None;
        self.active = self.queue.pop_front();
        self.selected_idx = 0;
        if self.active.is_some() {
            self.render_active(stdout)?;
        }
        Ok(())
    }

    async fn resolve_request(
        &self,
        request: &ApprovalRequest,
        choice: &ApprovalChoice,
        selected_prefix: Option<&str>,
    ) -> anyhow::Result<()> {
        let url = local_http_url(self.port, "/ai/sessions/approvals/resolve");
        let response = self
            .http
            .post(url)
            .json(&ResolveApprovalPayload {
                session_id: request.ai_session_id.as_str(),
                request_id: Some(request.request_id.as_str()),
                capability_key: request.capability_key.as_str(),
                agent_id: (!request.agent_id.is_empty()).then_some(request.agent_id.as_str()),
                decision: choice.decision,
                scope: choice.scope,
                approval_kind: request.approval_kind.as_deref(),
                prefix: selected_prefix.or_else(|| request.prefix_for_scope(choice.scope)),
            })
            .send()
            .await
            .context("failed to submit approval resolution")?;
        response
            .error_for_status()
            .context("approval resolution was rejected")?;
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct ApprovalRequest {
    ai_session_id: String,
    request_id: String,
    capability_key: String,
    agent_id: String,
    model_id: String,
    cwd: Option<String>,
    approval_kind: Option<String>,
    supported_scopes: Vec<&'static str>,
    shell_command: Option<String>,
    shell_prefix_candidates: Vec<String>,
}

impl ApprovalRequest {
    fn from_payload(body: &serde_json::Value) -> Option<Self> {
        let ai_session_id = string_field(body, "ai_session_id")?;
        let request_id = string_field(body, "request_id")?;
        let capability_key = string_field(body, "capability_key")?;
        Some(Self {
            ai_session_id,
            request_id,
            capability_key,
            agent_id: string_field(body, "agent_id").unwrap_or_default(),
            model_id: string_field(body, "model_id").unwrap_or_default(),
            cwd: string_field(body, "cwd"),
            approval_kind: string_field(body, "approval_kind"),
            supported_scopes: parse_supported_scopes(body),
            shell_command: string_field(body, "shell_command"),
            shell_prefix_candidates: string_array_field(body, "shell_prefix_candidates"),
        })
    }

    fn dedupe_key(&self) -> String {
        // Request ids are generated by the approval authority and are the only
        // stable identity across the raw CLI, Desktop, mobile and embedded TUI.
        // Falling back to capability is only for defensive parsing of legacy
        // events that lacked request ids; normal events always carry one.
        if !self.request_id.is_empty() {
            return format!("request:{}", self.request_id);
        }
        format!(
            "capability:{}:{}:{}",
            self.ai_session_id, self.agent_id, self.capability_key
        )
    }

    fn conflicts_with(&self, other: &Self) -> bool {
        self.dedupe_key() == other.dedupe_key()
    }

    fn matches_resolution(
        &self,
        request_id: &str,
        ai_session_id: &str,
        agent_id: &str,
        capability_key: &str,
    ) -> bool {
        if !request_id.trim().is_empty() {
            return self.request_id == request_id.trim();
        }
        self.ai_session_id == ai_session_id.trim()
            && self.agent_id == agent_id.trim()
            && self.capability_key == capability_key.trim()
    }

    fn choices(&self) -> Vec<ApprovalChoice> {
        let mut choices = Vec::new();
        for scope in &self.supported_scopes {
            choices.push(ApprovalChoice {
                decision: "allow",
                scope,
            });
            choices.push(ApprovalChoice {
                decision: "deny",
                scope,
            });
        }
        choices
    }

    fn prefix_for_scope(&self, scope: &str) -> Option<&str> {
        if !self.is_shell() || scope.eq_ignore_ascii_case("once") {
            return None;
        }
        self.shell_prefix_candidates.first().map(String::as_str)
    }

    fn requires_prefix_selection(&self, choice: &ApprovalChoice) -> bool {
        self.is_shell()
            && !choice.scope.eq_ignore_ascii_case("once")
            && !self.shell_prefix_candidates.is_empty()
    }

    fn is_shell(&self) -> bool {
        self.approval_kind
            .as_deref()
            .is_some_and(|kind| kind.eq_ignore_ascii_case("shell"))
    }

    fn prompt_title(&self) -> &'static str {
        // Match Codex approval_overlay titles instead of showing a Sirix-only
        // banner. The raw CLI still uses Sirix's shared approval transport, but
        // the visible approval question should read like Codex so option colors
        // and hierarchy are perceived consistently across endpoints.
        if self.is_shell() {
            "Would you like to run the following command?"
        } else {
            "Would you like to allow this capability?"
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct ApprovalChoice {
    decision: &'static str,
    scope: &'static str,
}

#[derive(Clone, Debug)]
struct PendingPrefixSelection {
    request: ApprovalRequest,
    choice: ApprovalChoice,
    prefixes: Vec<String>,
}

impl PendingPrefixSelection {
    fn overlay_lines(&self, selected_idx: usize) -> Vec<String> {
        let mut lines = vec![
            format!("  {ANSI_BOLD}Choose the command prefix to persist.{ANSI_RESET}"),
            String::new(),
        ];
        if let Some(command) = self.request.shell_command.as_deref() {
            lines.push(format!("  $ {command}"));
            lines.push(String::new());
        }
        for (idx, prefix) in self.prefixes.iter().enumerate() {
            let label = format!("{}. {prefix}", idx + 1);
            if idx == selected_idx {
                lines.push(format!("  {ANSI_CYAN_BOLD}{label}{ANSI_RESET}"));
            } else {
                lines.push(format!("  {label}"));
            }
        }
        lines.push(format!(
            "  {ANSI_DIM}number/enter{ANSI_RESET} selects · {ANSI_DIM}↑/↓ or j/k{ANSI_RESET} moves · {ANSI_DIM}Ctrl-C{ANSI_RESET} detaches"
        ));
        lines
    }
}

#[derive(serde::Serialize)]
struct ResolveApprovalPayload<'a> {
    session_id: &'a str,
    request_id: Option<&'a str>,
    capability_key: &'a str,
    agent_id: Option<&'a str>,
    decision: &'a str,
    scope: &'a str,
    approval_kind: Option<&'a str>,
    prefix: Option<&'a str>,
}

fn string_field(body: &serde_json::Value, key: &str) -> Option<String> {
    body.get(key)
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn write_overlay_line<W: Write>(stdout: &mut W, args: fmt::Arguments<'_>) -> anyhow::Result<()> {
    // Use CR + clear-line + CRLF for every overlay row. This keeps rendering
    // stable across macOS/Linux/Windows terminals in raw mode, including PTYs
    // where `\n` alone does not imply carriage return.
    write!(stdout, "\r\x1b[K").context("failed to prepare approval overlay line")?;
    stdout
        .write_fmt(args)
        .context("failed to write approval overlay line")?;
    write!(stdout, "\x1b[K\r\n").context("failed to finish approval overlay line")?;
    Ok(())
}

fn string_array_field(body: &serde_json::Value, key: &str) -> Vec<String> {
    body.get(key)
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
        .collect()
}

fn is_stale_resolution_error(error: &anyhow::Error) -> bool {
    error
        .chain()
        .filter_map(|cause| cause.downcast_ref::<reqwest::Error>())
        .filter_map(reqwest::Error::status)
        .any(|status| matches!(status.as_u16(), 400 | 404 | 409))
}

fn parse_supported_scopes(body: &serde_json::Value) -> Vec<&'static str> {
    let mut scopes = Vec::new();
    for raw in string_array_field(body, "supported_scopes") {
        let scope = match raw.to_ascii_lowercase().as_str() {
            "once" => "once",
            "session" => "session",
            "workspace" => "workspace",
            "global" => "global",
            _ => continue,
        };
        if !scopes.contains(&scope) {
            scopes.push(scope);
        }
    }
    if scopes.is_empty() {
        vec!["once", "session"]
    } else {
        scopes
    }
}

#[path = "cli_approval_display.rs"]
mod display;

#[cfg(test)]
#[path = "cli_approval_tests.rs"]
mod tests;
