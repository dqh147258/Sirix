use std::env;
use std::time::Duration;

use codex_login::default_client::build_reqwest_client;
use serde::Deserialize;
use serde::Serialize;
use tokio::time::sleep;

const SIRIX_LOCAL_API_BASE_ENV: &str = "SIRIX_LOCAL_API_BASE";
const SIRIX_AI_SESSION_ID_ENV: &str = "SIRIX_AI_SESSION_ID";
const SIRIX_APPROVAL_POLL_INTERVAL: Duration = Duration::from_millis(350);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SirixToolApprovalDecision {
    Allow,
    Deny,
}

#[derive(Debug, Serialize)]
struct SirixCheckApprovalRequest<'a> {
    session_id: &'a str,
    capability_key: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_id: Option<&'a str>,
}

#[derive(Debug, Deserialize)]
struct SirixCheckApprovalResponse {
    outcome: String,
}

pub(crate) fn mcp_capability_key(server: &str, tool_name: &str) -> String {
    format!("mcp.{server}.{tool_name}")
}

pub(crate) async fn wait_for_sirix_tool_approval(
    capability_key: &str,
    agent_id: Option<&str>,
) -> Result<Option<SirixToolApprovalDecision>, String> {
    let Some(local_api_base) = env::var(SIRIX_LOCAL_API_BASE_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    else {
        // Keep standalone Codex behavior unchanged when the Sirix desktop host
        // is not present.
        return Ok(None);
    };

    let Some(session_id) = env::var(SIRIX_AI_SESSION_ID_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };

    let client = build_reqwest_client();
    let url = format!(
        "{}/ai/sessions/approvals/check",
        local_api_base.trim_end_matches('/')
    );

    loop {
        let response = client
            .post(&url)
            .json(&SirixCheckApprovalRequest {
                session_id: session_id.as_str(),
                capability_key,
                agent_id,
            })
            .send()
            .await
            .map_err(|error| {
                format!(
                    "failed to query Sirix approval state for capability `{capability_key}`: {error}"
                )
            })?;

        let response = response.error_for_status().map_err(|error| {
            format!(
                "Sirix approval service rejected approval check for capability `{capability_key}`: {error}"
            )
        })?;

        let payload = response
            .json::<SirixCheckApprovalResponse>()
            .await
            .map_err(|error| {
                format!(
                    "failed to decode Sirix approval response for capability `{capability_key}`: {error}"
                )
            })?;

        match payload.outcome.trim().to_ascii_lowercase().as_str() {
            "allow" => return Ok(Some(SirixToolApprovalDecision::Allow)),
            "deny" => return Ok(Some(SirixToolApprovalDecision::Deny)),
            "ask" => sleep(SIRIX_APPROVAL_POLL_INTERVAL).await,
            other => {
                return Err(format!(
                    "Sirix approval service returned unsupported outcome `{other}` for capability `{capability_key}`"
                ));
            }
        }
    }
}
