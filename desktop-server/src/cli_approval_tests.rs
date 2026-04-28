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
    assert!(rendered.contains("Capability key: skill.beta"));
    assert!(rendered.contains("number/enter\u{1b}[0m selects"));
}

#[test]
fn rendered_overlay_uses_codex_like_selection_colors() {
    let mut prompt = CliApprovalPrompt::new(9, "test");
    let mut stdout = Vec::new();

    prompt
        .handle_request_event(&mut stdout, &request_body("request-1", "skill.alpha"))
        .expect("request should render");

    let rendered = String::from_utf8(stdout).expect("approval prompt should be utf8");
    assert!(rendered.contains("  \u{1b}[1mWould you like to allow this capability?\u{1b}[0m"));
    assert!(rendered.contains("  Requested function: alpha"));
    assert!(rendered.contains("  Function type: Skill"));
    assert!(rendered.contains("  Capability key: skill.alpha"));
    assert!(rendered
        .contains("  \u{1b}[1m\u{1b}[36m1. Yes, grant these permissions for this turn\u{1b}[0m"));
    assert!(rendered.contains("  2. No, continue without permissions"));
    assert!(rendered.contains("number/enter\u{1b}[0m selects"));
    assert!(
        !rendered.contains("\u{1b}[33m"),
        "approval overlay should not use yellow; Codex uses cyan selected rows, default unselected rows, and dim hints"
    );
}

#[test]
fn rendered_overlay_uses_crlf_to_avoid_raw_terminal_stair_step() {
    let mut prompt = CliApprovalPrompt::new(9, "test");
    let mut stdout = Vec::new();

    prompt
        .handle_request_event(&mut stdout, &request_body("request-1", "skill.alpha"))
        .expect("request should render");

    assert!(
        !stdout
            .windows(b"\x1b[2J".len())
            .any(|window| window == b"\x1b[2J"),
        "approval overlay should not clear the full screen; Codex renders approvals as a bottom pane"
    );
    for (idx, byte) in stdout.iter().enumerate() {
        if *byte == b'\n' {
            assert_eq!(
                stdout.get(idx.saturating_sub(1)),
                Some(&b'\r'),
                "overlay line feed at byte {idx} must be preceded by carriage return"
            );
        }
    }
}

#[tokio::test]
async fn unknown_keys_do_not_repaint_or_append_warning_lines() {
    let mut prompt = CliApprovalPrompt::new(9, "test");
    let mut stdout = Vec::new();

    prompt
        .handle_request_event(&mut stdout, &request_body("request-1", "skill.alpha"))
        .expect("request should render");
    stdout.clear();

    prompt
        .handle_stdin_bytes(&mut stdout, b"x")
        .await
        .expect("unknown input should be consumed");

    let rendered = String::from_utf8(stdout).expect("approval prompt should be utf8");
    assert_eq!(rendered, "\u{7}");
    assert!(!rendered.contains("approval pending for"));
    assert!(!rendered.contains("\u{1b}[33m"));
}

#[tokio::test]
async fn arrow_keys_repaint_codex_style_menu_in_place() {
    let mut prompt = CliApprovalPrompt::new(9, "test");
    let mut stdout = Vec::new();

    prompt
        .handle_request_event(&mut stdout, &request_body("request-1", "skill.alpha"))
        .expect("request should render");
    stdout.clear();

    prompt
        .handle_stdin_bytes(&mut stdout, b"\x1b[B")
        .await
        .expect("down arrow should be consumed");

    let rendered = String::from_utf8(stdout).expect("approval prompt should be utf8");
    assert!(
        rendered.contains("\x1b[1A\r\x1b[2K"),
        "selection changes should repaint only the approval menu rows, not clear the screen"
    );
    assert!(rendered.contains("  \x1b[1m\x1b[36m2. No, continue without permissions\x1b[0m"));
    assert!(!rendered.contains("\x1b[2J"));
    assert_eq!(prompt.selected_idx, 1);
}

#[tokio::test]
async fn soft_wrapped_overlay_rows_are_fully_cleared_on_repaint() {
    let mut prompt = CliApprovalPrompt::new(9, "test");
    prompt.set_terminal_width(24);
    let mut stdout = Vec::new();

    prompt
        .handle_request_event(&mut stdout, &request_body("request-1", "skill.alpha"))
        .expect("request should render");
    let rendered_rows = prompt.last_rendered_row_count;
    assert!(
        rendered_rows
            > prompt
                .overlay_lines(
                    prompt.active.as_ref().expect("active request"),
                    &prompt.active.as_ref().expect("active request").choices(),
                    prompt.selected_idx,
                )
                .len(),
        "narrow terminals should count soft-wrapped visual rows, not logical lines"
    );
    stdout.clear();

    prompt
        .handle_stdin_bytes(&mut stdout, b"\x1b[B")
        .await
        .expect("down arrow should repaint");

    let clear_count = stdout
        .windows(b"\x1b[1A\r\x1b[2K".len())
        .filter(|window| *window == b"\x1b[1A\r\x1b[2K")
        .count();
    assert_eq!(
        clear_count, rendered_rows,
        "repaint must clear every visible row so stale wrapped approval panes cannot remain onscreen"
    );
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

    assert!(request.matches_resolution("request-1", "wrong-session", "wrong-agent", "skill.beta"));
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

#[test]
fn same_capability_with_new_request_id_is_queued_as_distinct_gate() {
    let mut prompt = CliApprovalPrompt::new(9, "test");
    let mut stdout = Vec::new();

    prompt
        .handle_request_event(&mut stdout, &request_body("request-1", "skill.alpha"))
        .expect("first request should render");
    prompt
        .handle_request_event(&mut stdout, &request_body("request-2", "skill.alpha"))
        .expect("same capability with a fresh id should queue as a separate approval gate");

    assert_eq!(active_request_id(&prompt), Some("request-1"));
    assert_eq!(prompt.queue.len(), 1);
}

#[tokio::test]
async fn persistent_shell_choice_opens_prefix_selection_before_resolving() {
    let mut prompt = CliApprovalPrompt::new(9, "test");
    let mut stdout = Vec::new();

    prompt
        .handle_request_event(&mut stdout, &shell_request_body("request-shell"))
        .expect("shell request should render");
    stdout.clear();

    prompt
        .handle_stdin_bytes(&mut stdout, b"3")
        .await
        .expect("allow session should open prefix selection");

    assert!(prompt.prefix_selection.is_some());
    assert_eq!(active_request_id(&prompt), Some("request-shell"));
    let rendered = String::from_utf8(stdout).expect("approval prompt should be utf8");
    assert!(rendered.contains("Choose the command prefix to persist."));
    assert!(rendered.contains("1. cargo test"));
    assert!(rendered.contains("2. cargo"));
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

fn shell_request_body(request_id: &str) -> serde_json::Value {
    serde_json::json!({
        "ai_session_id": "session-1",
        "request_id": request_id,
        "capability_key": "builtin.shell",
        "approval_kind": "shell",
        "agent_id": "agent-1",
        "model_id": "model-1",
        "supported_scopes": ["once", "session"],
        "shell_command": "cargo test",
        "shell_prefix_candidates": ["cargo test", "cargo"],
    })
}
