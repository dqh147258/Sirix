use anyhow::Context;
use reqwest::StatusCode;
use serde::Deserialize;
use serde::Serialize;
use std::time::Duration;

const SIRIX_SHELL_APPROVAL_POLL_INTERVAL: Duration = Duration::from_millis(350);

const SIRIX_LOCAL_API_BASE_ENV: &str = "SIRIX_LOCAL_API_BASE";
const SIRIX_AI_SESSION_ID_ENV: &str = "SIRIX_AI_SESSION_ID";

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SessionAgentSummary {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) description: String,
    pub(crate) provider_id: String,
    pub(crate) model_id: String,
    pub(crate) effective_context_window: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SessionAgentsResponse {
    pub(crate) current_agent_id: String,
    pub(crate) agents: Vec<SessionAgentSummary>,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SwitchSessionAgentResponse {
    pub(crate) agent_id: String,
    pub(crate) name: String,
    pub(crate) model_id: String,
    pub(crate) effective_context_window: u32,
    pub(crate) developer_instructions: String,
}

#[derive(Debug, Serialize)]
struct SwitchSessionAgentRequest<'a> {
    agent_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    current_tokens_in_context: Option<i64>,
}

#[derive(Debug, Serialize)]
struct ResolveSessionShellRuleRequest<'a> {
    decision: &'a str,
    scope: &'a str,
    prefix: &'a str,
}

#[derive(Debug, Serialize)]
struct CreateSessionShellApprovalRequest<'a> {
    request_id: &'a str,
    command: &'a [String],
    supported_scopes: &'a [String],
    prefix_candidates: &'a [String],
}

#[derive(Debug, Serialize)]
struct CheckSessionShellApprovalRequest<'a> {
    request_id: &'a str,
}

#[derive(Debug, Serialize)]
struct ResolveSessionShellApprovalRequest<'a> {
    request_id: &'a str,
    decision: &'a str,
    scope: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    prefix: Option<&'a str>,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SessionShellApprovalResolution {
    pub(crate) outcome: String,
    pub(crate) decision: Option<String>,
    pub(crate) scope: Option<String>,
    pub(crate) prefix: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ResolveSessionShellApprovalOutcome {
    Resolved,
    AlreadyResolved,
}

fn session_url(path: &str) -> anyhow::Result<String> {
    let base = std::env::var(SIRIX_LOCAL_API_BASE_ENV)
        .context("SIRIX_LOCAL_API_BASE is not set for this session")?;
    let session_id =
        std::env::var(SIRIX_AI_SESSION_ID_ENV).context("SIRIX_AI_SESSION_ID is not set")?;
    Ok(format!(
        "{}/ai/sessions/{session_id}/{}",
        base.trim_end_matches('/'),
        path.trim_start_matches('/')
    ))
}

pub(crate) fn is_available() -> bool {
    std::env::var(SIRIX_LOCAL_API_BASE_ENV)
        .ok()
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false)
        && std::env::var(SIRIX_AI_SESSION_ID_ENV)
            .ok()
            .map(|value| !value.trim().is_empty())
            .unwrap_or(false)
}

pub(crate) async fn list_session_agents() -> anyhow::Result<SessionAgentsResponse> {
    let response = reqwest::Client::new()
        .get(session_url("agents")?)
        .send()
        .await
        .context("failed to query Sirix session agents")?
        .error_for_status()
        .context("failed to load Sirix session agents")?;
    response
        .json::<SessionAgentsResponse>()
        .await
        .context("failed to decode Sirix session agents")
}

pub(crate) async fn switch_session_agent(
    agent_id: &str,
    current_tokens_in_context: Option<i64>,
) -> anyhow::Result<SwitchSessionAgentResponse> {
    let response = reqwest::Client::new()
        .post(session_url("agent")?)
        .json(&SwitchSessionAgentRequest {
            agent_id,
            current_tokens_in_context,
        })
        .send()
        .await
        .context("failed to switch Sirix agent")?
        .error_for_status()
        .context("Sirix agent switch request failed")?;
    response
        .json::<SwitchSessionAgentResponse>()
        .await
        .context("failed to decode Sirix agent switch response")
}

pub(crate) async fn resolve_session_shell_rule(
    decision: &str,
    scope: &str,
    prefix: &str,
) -> anyhow::Result<()> {
    reqwest::Client::new()
        .post(session_url("shell-rules/resolve")?)
        .json(&ResolveSessionShellRuleRequest {
            decision,
            scope,
            prefix,
        })
        .send()
        .await
        .context("failed to persist Sirix shell rule")?
        .error_for_status()
        .context("Sirix shell rule persistence failed")?;
    Ok(())
}

pub(crate) async fn create_session_shell_approval_request(
    request_id: &str,
    command: &[String],
    supported_scopes: &[String],
    prefix_candidates: &[String],
) -> anyhow::Result<()> {
    reqwest::Client::new()
        .post(session_url("shell-approvals/request")?)
        .json(&CreateSessionShellApprovalRequest {
            request_id,
            command,
            supported_scopes,
            prefix_candidates,
        })
        .send()
        .await
        .context("failed to publish Sirix shell approval request")?
        .error_for_status()
        .context("Sirix shell approval request failed")?;
    Ok(())
}

pub(crate) async fn check_session_shell_approval(
    request_id: &str,
) -> anyhow::Result<SessionShellApprovalResolution> {
    let response = reqwest::Client::new()
        .post(session_url("shell-approvals/check")?)
        .json(&CheckSessionShellApprovalRequest { request_id })
        .send()
        .await
        .context("failed to check Sirix shell approval")?
        .error_for_status()
        .context("Sirix shell approval check failed")?;
    response
        .json::<SessionShellApprovalResolution>()
        .await
        .context("failed to decode Sirix shell approval check")
}

pub(crate) async fn wait_for_session_shell_approval(
    request_id: &str,
) -> anyhow::Result<SessionShellApprovalResolution> {
    loop {
        let payload = check_session_shell_approval(request_id).await?;
        match payload.outcome.trim().to_ascii_lowercase().as_str() {
            "allow" | "deny" => return Ok(payload),
            _ => tokio::time::sleep(SIRIX_SHELL_APPROVAL_POLL_INTERVAL).await,
        }
    }
}

pub(crate) async fn resolve_session_shell_approval(
    request_id: &str,
    decision: &str,
    scope: &str,
    prefix: Option<&str>,
) -> anyhow::Result<ResolveSessionShellApprovalOutcome> {
    let response = reqwest::Client::new()
        .post(session_url("shell-approvals/resolve")?)
        .json(&ResolveSessionShellApprovalRequest {
            request_id,
            decision,
            scope,
            prefix,
        })
        .send()
        .await
        .context("failed to resolve Sirix shell approval")?;

    match response.status() {
        status if status.is_success() => Ok(ResolveSessionShellApprovalOutcome::Resolved),
        // A duplicated approval surface can race after another endpoint already
        // resolved the same shell request. Treat the desktop API's stale-claim
        // responses as terminal, non-fatal outcomes; callers must not submit a
        // second Codex ExecApproval for this id.
        StatusCode::NOT_FOUND | StatusCode::CONFLICT => {
            Ok(ResolveSessionShellApprovalOutcome::AlreadyResolved)
        }
        _ => {
            response
                .error_for_status()
                .context("Sirix shell approval resolve failed")?;
            Ok(ResolveSessionShellApprovalOutcome::Resolved)
        }
    }
}
