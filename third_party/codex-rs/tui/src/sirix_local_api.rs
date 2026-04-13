use anyhow::Context;
use serde::Deserialize;
use serde::Serialize;

const SIRIX_LOCAL_API_BASE_ENV: &str = "SIRIX_LOCAL_API_BASE";
const SIRIX_AI_SESSION_ID_ENV: &str = "SIRIX_AI_SESSION_ID";

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SessionAgentSummary {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) description: String,
    pub(crate) provider_id: String,
    pub(crate) model_id: String,
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
    pub(crate) provider_id: String,
    pub(crate) model_id: String,
    pub(crate) developer_instructions: String,
}

#[derive(Debug, Serialize)]
struct SwitchSessionAgentRequest<'a> {
    agent_id: &'a str,
}

#[derive(Debug, Serialize)]
struct ResolveSessionShellRuleRequest<'a> {
    decision: &'a str,
    scope: &'a str,
    prefix: &'a str,
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
) -> anyhow::Result<SwitchSessionAgentResponse> {
    let response = reqwest::Client::new()
        .post(session_url("agent")?)
        .json(&SwitchSessionAgentRequest { agent_id })
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
