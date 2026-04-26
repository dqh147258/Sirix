use std::collections::VecDeque;
use std::io::Write;

use anyhow::Context;

use crate::cli_support::local_http_url;

/// Sirix raw terminal approval UI.
///
/// Desktop/Mobile already consume the unified `ai.approval.request` /
/// `ai.approval.resolved` event stream.  The standalone `sirix` and
/// `sirix-terminal` binaries attach to the same websocket, but they run in raw
/// terminal mode and must explicitly intercept keystrokes while an approval is
/// pending.  Keeping that logic here prevents the two CLI entrypoints from
/// drifting into different approval protocols.
pub(crate) struct CliApprovalPrompt {
    port: u16,
    client_name: &'static str,
    http: reqwest::Client,
    active: Option<ApprovalRequest>,
    queue: VecDeque<ApprovalRequest>,
}

impl CliApprovalPrompt {
    pub(crate) fn new(port: u16, client_name: &'static str) -> Self {
        Self {
            port,
            client_name,
            http: reqwest::Client::new(),
            active: None,
            queue: VecDeque::new(),
        }
    }

    pub(crate) fn has_pending(&self) -> bool {
        self.active.is_some()
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
            self.render_active(stdout)?;
        } else {
            self.queue.push_back(request);
            self.render_queue_notice(stdout)?;
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

        self.queue.retain(|request| {
            !request.matches_resolution(request_id, ai_session_id, agent_id, capability_key)
        });
        if self.active.as_ref().is_some_and(|request| {
            request.matches_resolution(request_id, ai_session_id, agent_id, capability_key)
        }) {
            let decision = body
                .get("decision")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("resolved");
            writeln!(
                stdout,
                "\r\n\x1b[32m[{name}] approval {decision}; continuing.\x1b[0m",
                name = self.client_name,
            )
            .context("failed to write approval resolution notice")?;
            self.active = self.queue.pop_front();
            if self.active.is_some() {
                self.render_active(stdout)?;
            }
        }
        stdout.flush().ok();
        Ok(())
    }

    pub(crate) async fn handle_stdin_bytes<W: Write>(
        &mut self,
        stdout: &mut W,
        bytes: &[u8],
    ) -> anyhow::Result<()> {
        let Some(choice) = self.choice_from_input(bytes) else {
            self.render_short_hint(stdout)?;
            return Ok(());
        };
        let Some(request) = self.active.clone() else {
            return Ok(());
        };
        let outcome_label = format!("{} {}", choice.decision, choice.scope);
        match self.resolve_request(&request, &choice).await {
            Ok(()) => {
                writeln!(
                    stdout,
                    "\r\n\x1b[32m[{name}] submitted approval: {outcome_label}.\x1b[0m",
                    name = self.client_name,
                )
                .context("failed to write approval submit notice")?;
                self.active = self.queue.pop_front();
                if self.active.is_some() {
                    self.render_active(stdout)?;
                }
            }
            Err(error) => {
                // A 409/400 here commonly means another endpoint already
                // resolved the same request.  Keep the message visible but do
                // not blindly retry, otherwise stale CLI prompts could fight
                // with Desktop/Mobile decisions.
                writeln!(
                    stdout,
                    "\r\n\x1b[31m[{name}] failed to submit approval: {error}\x1b[0m",
                    name = self.client_name,
                )
                .context("failed to write approval error")?;
                writeln!(
                    stdout,
                    "\x1b[33m[{name}] approval is still pending; choose again or wait for another endpoint to resolve it.\x1b[0m",
                    name = self.client_name,
                )
                .context("failed to write approval retry hint")?;
                self.render_active(stdout)?;
            }
        }
        stdout.flush().ok();
        Ok(())
    }

    fn contains_request(&self, request: &ApprovalRequest) -> bool {
        self.active
            .as_ref()
            .is_some_and(|active| active.dedupe_key() == request.dedupe_key())
            || self
                .queue
                .iter()
                .any(|queued| queued.dedupe_key() == request.dedupe_key())
    }

    fn render_active<W: Write>(&self, stdout: &mut W) -> anyhow::Result<()> {
        let Some(request) = self.active.as_ref() else {
            return Ok(());
        };
        writeln!(
            stdout,
            "\r\n\x1b[33m[{name}] approval required\x1b[0m",
            name = self.client_name,
        )
        .context("failed to write approval prompt")?;
        writeln!(stdout, "  capability: {}", request.capability_key)
            .context("failed to write approval capability")?;
        if let Some(kind) = request.approval_kind.as_deref() {
            writeln!(stdout, "  kind: {kind}").context("failed to write approval kind")?;
        }
        if !request.agent_id.is_empty() || !request.model_id.is_empty() {
            writeln!(
                stdout,
                "  agent/model: {} · {}",
                request.agent_id, request.model_id
            )
            .context("failed to write approval agent")?;
        }
        if let Some(cwd) = request.cwd.as_deref().filter(|value| !value.is_empty()) {
            writeln!(stdout, "  cwd: {cwd}").context("failed to write approval cwd")?;
        }
        if let Some(command) = request
            .shell_command
            .as_deref()
            .filter(|value| !value.is_empty())
        {
            writeln!(stdout, "  command: {command}").context("failed to write shell command")?;
        }
        if !request.shell_prefix_candidates.is_empty() {
            writeln!(
                stdout,
                "  shell prefix: {}",
                request.shell_prefix_candidates[0]
            )
            .context("failed to write shell prefix")?;
        }
        writeln!(stdout, "  choose:").context("failed to write approval choices")?;
        for (idx, choice) in request.choices().iter().enumerate() {
            writeln!(
                stdout,
                "    {}) {} {}",
                idx + 1,
                choice.decision,
                choice.scope
            )
            .context("failed to write approval choice")?;
        }
        // Raw terminal mode delivers each key immediately.  Call out that Enter
        // is not required so an extra newline does not get forwarded to the PTY
        // after the approval prompt clears.
        writeln!(
            stdout,
            "  press one listed number (no Enter); Esc/Ctrl-C = deny once"
        )
        .context("failed to write approval hint")?;
        stdout.flush().ok();
        Ok(())
    }

    fn render_queue_notice<W: Write>(&self, stdout: &mut W) -> anyhow::Result<()> {
        writeln!(
            stdout,
            "\r\n\x1b[33m[{name}] another approval is queued ({count} waiting).\x1b[0m",
            name = self.client_name,
            count = self.queue.len(),
        )
        .context("failed to write approval queue notice")?;
        stdout.flush().ok();
        Ok(())
    }

    fn render_short_hint<W: Write>(&self, stdout: &mut W) -> anyhow::Result<()> {
        if let Some(request) = self.active.as_ref() {
            writeln!(
                stdout,
                "\r\n\x1b[33m[{name}] approval pending for {}; press one listed number (no Enter), Esc, or Ctrl-C.\x1b[0m",
                request.capability_key,
                name = self.client_name,
            )
            .context("failed to write approval short hint")?;
        }
        stdout.flush().ok();
        Ok(())
    }

    fn choice_from_input(&self, bytes: &[u8]) -> Option<ApprovalChoice> {
        let request = self.active.as_ref()?;
        let first = bytes.first().copied()?;
        if first == 0x03 || first == 0x1b {
            return Some(ApprovalChoice {
                decision: "deny",
                scope: "once",
            });
        }
        let digit = char::from(first).to_digit(10)?;
        if digit == 0 {
            return None;
        }
        let idx = usize::try_from(digit).ok()?.checked_sub(1)?;
        request.choices().get(idx).copied()
    }

    async fn resolve_request(
        &self,
        request: &ApprovalRequest,
        choice: &ApprovalChoice,
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
                prefix: request.prefix_for_scope(choice.scope),
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
        if !self.request_id.is_empty() {
            return format!("request:{}", self.request_id);
        }
        format!(
            "capability:{}:{}:{}",
            self.ai_session_id, self.agent_id, self.capability_key
        )
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

    fn is_shell(&self) -> bool {
        self.approval_kind
            .as_deref()
            .is_some_and(|kind| kind.eq_ignore_ascii_case("shell"))
            || self.capability_key == "builtin.shell"
    }
}

#[derive(Clone, Copy, Debug)]
struct ApprovalChoice {
    decision: &'static str,
    scope: &'static str,
}

#[derive(serde::Serialize)]
struct ResolveApprovalPayload<'a> {
    session_id: &'a str,
    request_id: Option<&'a str>,
    capability_key: &'a str,
    agent_id: Option<&'a str>,
    decision: &'a str,
    scope: &'a str,
    prefix: Option<&'a str>,
}

fn string_field(body: &serde_json::Value, key: &str) -> Option<String> {
    body.get(key)
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_capability_request_choices() {
        let body = serde_json::json!({
            "ai_session_id": "s",
            "request_id": "r",
            "capability_key": "skill.implementation-planner",
            "supported_scopes": ["once", "workspace"],
        });
        let request = ApprovalRequest::from_payload(&body).expect("request");
        let choices = request.choices();
        assert_eq!(choices.len(), 4);
        assert_eq!(choices[0].decision, "allow");
        assert_eq!(choices[0].scope, "once");
        assert_eq!(choices[3].decision, "deny");
        assert_eq!(choices[3].scope, "workspace");
    }

    #[test]
    fn shell_prefix_only_applies_to_persistent_scopes() {
        let body = serde_json::json!({
            "ai_session_id": "s",
            "request_id": "r",
            "capability_key": "builtin.shell",
            "approval_kind": "shell",
            "supported_scopes": ["once", "session"],
            "shell_prefix_candidates": ["npm test"],
        });
        let request = ApprovalRequest::from_payload(&body).expect("request");
        assert_eq!(request.prefix_for_scope("once"), None);
        assert_eq!(request.prefix_for_scope("session"), Some("npm test"));
    }

    #[test]
    fn resolved_event_promotes_next_queued_request() {
        let mut prompt = CliApprovalPrompt::new(9, "test");
        let mut stdout = Vec::new();
        prompt
            .handle_request_event(&mut stdout, &request_body("request-1", "skill.alpha"))
            .expect("first request should render");
        prompt
            .handle_request_event(&mut stdout, &request_body("request-2", "skill.beta"))
            .expect("second request should queue");

        assert_eq!(active_request_id(&prompt), Some("request-1"));
        assert_eq!(prompt.queue.len(), 1);

        prompt
            .handle_resolved_event(
                &mut stdout,
                &serde_json::json!({
                    "request_id": "request-1",
                    "decision": "allow",
                }),
            )
            .expect("resolution should advance queue");

        assert_eq!(active_request_id(&prompt), Some("request-2"));
        assert_eq!(prompt.queue.len(), 0);
        let rendered = String::from_utf8(stdout).expect("approval prompt should be utf8");
        assert!(rendered.contains("capability: skill.beta"));
        assert!(rendered.contains("no Enter"));
    }

    #[test]
    fn resolved_event_removes_matching_queued_request_without_touching_active() {
        let mut prompt = CliApprovalPrompt::new(9, "test");
        let mut stdout = Vec::new();
        prompt
            .handle_request_event(&mut stdout, &request_body("request-1", "skill.alpha"))
            .expect("first request should render");
        prompt
            .handle_request_event(&mut stdout, &request_body("request-2", "skill.beta"))
            .expect("second request should queue");

        prompt
            .handle_resolved_event(
                &mut stdout,
                &serde_json::json!({
                    "request_id": "request-2",
                    "decision": "deny",
                }),
            )
            .expect("queued resolution should be accepted");

        assert_eq!(active_request_id(&prompt), Some("request-1"));
        assert_eq!(prompt.queue.len(), 0);
    }

    #[test]
    fn request_id_match_takes_precedence_over_capability_fields() {
        let request = request("request-1", "skill.alpha");

        assert!(request.matches_resolution(
            "request-1",
            "wrong-session",
            "wrong-agent",
            "skill.beta"
        ));
        assert!(!request.matches_resolution("request-2", "session-1", "agent-1", "skill.alpha"));
        assert!(request.matches_resolution("", "session-1", "agent-1", "skill.alpha"));
    }

    #[test]
    fn duplicate_request_event_is_not_queued_twice() {
        let mut prompt = CliApprovalPrompt::new(9, "test");
        let mut stdout = Vec::new();
        let body = request_body("request-1", "skill.alpha");

        prompt
            .handle_request_event(&mut stdout, &body)
            .expect("first request should render");
        prompt
            .handle_request_event(&mut stdout, &body)
            .expect("duplicate request should be ignored");

        assert_eq!(active_request_id(&prompt), Some("request-1"));
        assert_eq!(prompt.queue.len(), 0);
    }

    fn active_request_id(prompt: &CliApprovalPrompt) -> Option<&str> {
        prompt
            .active
            .as_ref()
            .map(|request| request.request_id.as_str())
    }

    fn request(request_id: &str, capability_key: &str) -> ApprovalRequest {
        ApprovalRequest::from_payload(&request_body(request_id, capability_key)).expect("request")
    }

    fn request_body(request_id: &str, capability_key: &str) -> serde_json::Value {
        serde_json::json!({
            "ai_session_id": "session-1",
            "request_id": request_id,
            "capability_key": capability_key,
            "agent_id": "agent-1",
            "model_id": "model-1",
            "supported_scopes": ["once", "session"],
        })
    }
}
