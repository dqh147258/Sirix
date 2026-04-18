use std::{
    collections::{BTreeMap, HashSet},
    convert::Infallible,
    path::{Path as StdPath, PathBuf},
};

use anyhow::Context;
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{
        header::CONTENT_TYPE, HeaderMap as AxumHeaderMap, HeaderValue as AxumHeaderValue,
        StatusCode,
    },
    response::{
        sse::{Event, Sse},
        IntoResponse, Response,
    },
    Json,
};
use codex_login::CodexAuth;
use codex_protocol::openai_models::{InputModality, ModelInfo, ModelVisibility, ModelsResponse};
use eventsource_stream::Eventsource;
use futures_util::StreamExt;
use reqwest::{
    header::{HeaderMap, HeaderName, HeaderValue, ACCEPT, AUTHORIZATION},
    Url,
};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

use crate::app::{
    ai::{
        approval::{ApprovalDecision, ApprovalRecord, ApprovalScope},
        config::{
            build_agent_system_prompt, build_agent_system_prompt_preview,
            duplicate_session_text_model_ids, effective_model_context_window,
            effective_model_runtime_context_window,
            infer_provider_default_context_window, normalized_sirix_config,
            resolve_session_picker_model, session_picker_model_id, validate_sirix_config,
            ApprovalMode, ModelConfig, ModelKind, ProviderConfig, ProviderKind, ShellRulesConfig,
            SirixConfig, ToolRulesConfig,
        },
        openai_auth::{provider_auth_manager, OpenAiAuthStatus, StartOpenAiAuthResponse},
        session::{
            launch_ai_session, launch_ai_session_in_current_terminal, reconfigure_ai_session_agent,
            validate_current_terminal_reuse_source, AiSessionLaunchResponse, AiSessionRecord,
        },
    },
    state::AppState,
};

#[derive(Debug, Deserialize)]
pub struct EffectiveConfigQuery {
    pub cwd: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ResolveSessionQuery {
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct LaunchAiSessionRequest {
    pub cwd: Option<String>,
    pub agent_id: Option<String>,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
    pub reuse_terminal_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CheckApprovalRequest {
    pub session_id: String,
    pub capability_key: String,
    pub agent_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ResolveApprovalRequest {
    pub session_id: String,
    pub capability_key: String,
    pub agent_id: Option<String>,
    pub decision: ApprovalDecision,
    pub scope: ApprovalScope,
}

#[derive(Debug, serde::Serialize)]
pub struct CheckApprovalResponse {
    pub outcome: String,
    pub configured_mode: ApprovalMode,
    pub cached: bool,
}

#[derive(Debug, serde::Serialize)]
pub struct ProviderModelsResponse {
    pub models: Vec<ModelConfig>,
}

#[derive(Debug, Deserialize)]
pub struct SwitchSessionAgentRequest {
    pub agent_id: String,
    pub current_tokens_in_context: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct SessionAgentSummary {
    pub id: String,
    pub name: String,
    pub description: String,
    pub provider_id: String,
    pub model_id: String,
    pub effective_context_window: u32,
    pub enabled: bool,
}

#[derive(Debug, Serialize)]
pub struct SessionAgentsResponse {
    pub current_agent_id: String,
    pub agents: Vec<SessionAgentSummary>,
}

#[derive(Debug, Serialize)]
pub struct SwitchSessionAgentResponse {
    pub agent_id: String,
    pub name: String,
    pub provider_id: String,
    pub model_id: String,
    pub effective_context_window: u32,
    pub developer_instructions: String,
}

#[derive(Debug, Deserialize)]
pub struct ResolveSessionShellRuleRequest {
    pub decision: ApprovalDecision,
    pub scope: String,
    pub prefix: String,
}

#[derive(Debug, Deserialize)]
pub struct AgentSystemPromptPreviewRequest {
    pub config: SirixConfig,
    pub agent_id: String,
    pub cwd: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AgentSystemPromptPreviewResponse {
    pub preview: JsonValue,
}

pub async fn get_openai_auth_status(
    Path(provider_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<OpenAiAuthStatus>, ApiError> {
    let status = state
        .openai_auth_registry
        .status(state.sirix_config_store.as_ref(), provider_id.as_str())
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(status))
}

pub async fn start_openai_auth_login(
    Path(provider_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<StartOpenAiAuthResponse>, ApiError> {
    let response = state
        .openai_auth_registry
        .clone()
        .start_browser_login(
            state.sirix_config_store.as_ref(),
            provider_id.as_str(),
            state.logger.clone(),
        )
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn logout_openai_auth(
    Path(provider_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    state
        .openai_auth_registry
        .logout(state.sirix_config_store.as_ref(), provider_id.as_str())
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn import_openai_auth_json(
    Path(provider_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<JsonValue>,
) -> Result<Json<serde_json::Value>, ApiError> {
    state
        .openai_auth_registry
        .import_auth_json(
            state.sirix_config_store.as_ref(),
            provider_id.as_str(),
            payload,
        )
        .await
        .map_err(ApiError::bad_request_anyhow)?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn get_ai_config(State(state): State<AppState>) -> Result<Json<SirixConfig>, ApiError> {
    let config = state
        .sirix_config_store
        .load_global()
        .map_err(ApiError::internal)?;
    Ok(Json(config))
}

pub async fn set_ai_config(
    State(state): State<AppState>,
    Json(payload): Json<SirixConfig>,
) -> Result<Json<SirixConfig>, ApiError> {
    let normalized = normalized_sirix_config(&payload);
    validate_sirix_config(&normalized).map_err(ApiError::bad_request_anyhow)?;
    state
        .sirix_config_store
        .save_global(&normalized)
        .map_err(ApiError::internal)?;
    Ok(Json(normalized))
}

pub async fn get_shell_rules(
    State(state): State<AppState>,
) -> Result<Json<ShellRulesConfig>, ApiError> {
    let rules = state
        .sirix_config_store
        .load_global_shell_rules()
        .map_err(ApiError::internal)?;
    Ok(Json(rules))
}

pub async fn set_shell_rules(
    State(state): State<AppState>,
    Json(payload): Json<ShellRulesConfig>,
) -> Result<Json<ShellRulesConfig>, ApiError> {
    state
        .sirix_config_store
        .save_global_shell_rules(&payload)
        .map_err(ApiError::internal)?;
    Ok(Json(payload))
}

pub async fn get_tool_rules(
    State(state): State<AppState>,
) -> Result<Json<ToolRulesConfig>, ApiError> {
    let rules = state
        .sirix_config_store
        .load_global_tool_rules()
        .map_err(ApiError::internal)?;
    Ok(Json(rules))
}

pub async fn set_tool_rules(
    State(state): State<AppState>,
    Json(payload): Json<ToolRulesConfig>,
) -> Result<Json<ToolRulesConfig>, ApiError> {
    state
        .sirix_config_store
        .save_global_tool_rules(&payload)
        .map_err(ApiError::internal)?;
    Ok(Json(payload))
}

pub async fn get_effective_ai_config(
    State(state): State<AppState>,
    Query(query): Query<EffectiveConfigQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let effective = state
        .sirix_config_store
        .effective_for_workspace(query.cwd.as_deref())
        .map_err(ApiError::internal)?;
    Ok(Json(
        serde_json::to_value(effective).map_err(|error| ApiError::internal(error.into()))?,
    ))
}

pub async fn preview_agent_system_prompt(
    State(state): State<AppState>,
    Json(payload): Json<AgentSystemPromptPreviewRequest>,
) -> Result<Json<AgentSystemPromptPreviewResponse>, ApiError> {
    let normalized = normalized_sirix_config(&payload.config);
    validate_sirix_config(&normalized).map_err(ApiError::bad_request_anyhow)?;
    let agent = normalized
        .agents
        .iter()
        .find(|candidate| candidate.id == payload.agent_id.trim())
        .cloned()
        .ok_or_else(|| {
            ApiError::bad_request(format!("agent not found: {}", payload.agent_id.trim()))
        })?;
    let workspace_root = payload
        .cwd
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok());
    let prompt = build_agent_system_prompt_preview(
        &normalized,
        &agent,
        state.sirix_config_store.sirix_home(),
        workspace_root.as_deref(),
    )
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(AgentSystemPromptPreviewResponse { preview: prompt }))
}

pub async fn discover_provider_models(
    State(state): State<AppState>,
    Json(provider): Json<ProviderConfig>,
) -> Result<Json<ProviderModelsResponse>, ApiError> {
    let models = match provider.kind {
        ProviderKind::OpenAiCodexOauth => discover_openai_codex_oauth_models(&state, &provider)
            .await
            .unwrap_or_else(|error| {
                state.logger.warn(format!(
                    "[OPENAI_OAUTH_MODELS] provider_id={} discovery_failed error={error}",
                    provider.id
                ));
                Vec::new()
            }),
        ProviderKind::OpenAiCodexApi => {
            fetch_provider_models(&provider)
                .await
                .unwrap_or_else(|error| {
                    state.logger.warn(format!(
                        "[OPENAI_CODEX_API_MODELS] provider_id={} discovery_failed error={error}",
                        provider.id
                    ));
                    Vec::new()
                })
        }
        _ => fetch_provider_models(&provider)
            .await
            .map_err(ApiError::internal)?,
    };
    Ok(Json(ProviderModelsResponse { models }))
}

pub async fn launch_session(
    State(state): State<AppState>,
    Json(payload): Json<LaunchAiSessionRequest>,
) -> Result<Json<AiSessionLaunchResponse>, ApiError> {
    let cwd = payload
        .cwd
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    let cols = payload.cols.unwrap_or(120).clamp(20, 400);
    let rows = payload.rows.unwrap_or(32).clamp(10, 200);
    let response = if let Some(reuse_terminal_id) = payload
        .reuse_terminal_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        let terminal_id = uuid::Uuid::parse_str(reuse_terminal_id)
            .map_err(|error| ApiError::bad_request(error.to_string()))?;
        let source = state
            .terminal_manager
            .session_source(terminal_id)
            .await
            .ok_or_else(|| {
                ApiError::bad_request(format!("terminal session not found for id={terminal_id}"))
            })?;
        if let Err(message) = validate_current_terminal_reuse_source(source) {
            return Err(ApiError::bad_request(message.to_string()));
        }
        launch_ai_session_in_current_terminal(
            &state,
            state.sirix_config_store.as_ref(),
            terminal_id,
            cwd.as_path(),
            payload.agent_id.as_deref(),
        )
        .await
        .map_err(ApiError::internal)?
    } else {
        launch_ai_session(
            &state,
            state.sirix_config_store.as_ref(),
            cwd.as_path(),
            payload.agent_id.as_deref(),
            cols,
            rows,
        )
        .await
        .map_err(ApiError::internal)?
    };
    Ok(Json(response))
}

pub async fn list_sessions(
    State(state): State<AppState>,
) -> Result<Json<Vec<AiSessionRecord>>, ApiError> {
    Ok(Json(state.ai_session_registry.list().await))
}

pub async fn list_session_agents(
    Path(ai_session_id): Path<uuid::Uuid>,
    State(state): State<AppState>,
) -> Result<Json<SessionAgentsResponse>, ApiError> {
    let runtime = state
        .ai_session_registry
        .resolve_runtime(ai_session_id)
        .await
        .ok_or_else(|| {
            ApiError::not_found(format!("ai session not found for id={ai_session_id}"))
        })?;
    let effective = state
        .sirix_config_store
        .effective_for_workspace(Some(runtime.workspace_root.to_string_lossy().as_ref()))
        .map_err(ApiError::internal)?;
    let agents = effective
        .config
        .agents
        .iter()
        .filter(|agent| agent.enabled)
        .filter_map(|agent| {
            let provider = effective
                .config
                .providers
                .iter()
                .find(|provider| provider.id == agent.provider_id)?;
            let model = provider
                .models
                .iter()
                .find(|model| model.id == agent.model_id)?;
            Some(SessionAgentSummary {
                id: agent.id.clone(),
                name: agent.name.clone(),
                description: agent.description.clone(),
                provider_id: agent.provider_id.clone(),
                model_id: agent.model_id.clone(),
                effective_context_window: effective_model_runtime_context_window(provider, model),
                enabled: agent.enabled,
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(SessionAgentsResponse {
        current_agent_id: runtime.agent_id,
        agents,
    }))
}

pub async fn switch_session_agent(
    Path(ai_session_id): Path<uuid::Uuid>,
    State(state): State<AppState>,
    Json(payload): Json<SwitchSessionAgentRequest>,
) -> Result<Json<SwitchSessionAgentResponse>, ApiError> {
    if payload.current_tokens_in_context.is_none() {
        return Err(ApiError::bad_request(
            "current_tokens_in_context is required when switching session agents".to_string(),
        ));
    }
    let (launch, _) = reconfigure_ai_session_agent(
        &state,
        state.sirix_config_store.as_ref(),
        ai_session_id,
        payload.agent_id.trim(),
        payload.current_tokens_in_context,
    )
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(SwitchSessionAgentResponse {
        agent_id: launch.agent.id.clone(),
        name: launch.agent.name.clone(),
        provider_id: launch.provider.id.clone(),
        model_id: launch.model.id.clone(),
        effective_context_window: effective_model_runtime_context_window(&launch.provider, &launch.model),
        developer_instructions: build_agent_system_prompt(&launch.effective_config, &launch.agent),
    }))
}

pub async fn resolve_session_shell_rule(
    Path(ai_session_id): Path<uuid::Uuid>,
    State(state): State<AppState>,
    Json(payload): Json<ResolveSessionShellRuleRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let runtime = state
        .ai_session_registry
        .resolve_runtime(ai_session_id)
        .await
        .ok_or_else(|| {
            ApiError::not_found(format!("ai session not found for id={ai_session_id}"))
        })?;
    let prefix = payload.prefix.trim();
    if prefix.is_empty() {
        return Err(ApiError::bad_request("prefix cannot be empty".to_string()));
    }

    let target_mode = match payload.decision {
        ApprovalDecision::Allow => ApprovalMode::Allow,
        ApprovalDecision::Deny => ApprovalMode::Deny,
    };
    match payload.scope.trim() {
        "session" => {
            state
                .ai_session_registry
                .push_session_shell_rule(ai_session_id, target_mode.clone(), prefix.to_string())
                .await
                .ok_or_else(|| {
                    ApiError::not_found(format!("ai session not found for id={ai_session_id}"))
                })?;
        }
        "workspace" => {
            let mut rules = state
                .sirix_config_store
                .load_workspace_shell_rules(runtime.workspace_root.as_path())
                .map_err(ApiError::internal)?
                .unwrap_or_default();
            match target_mode {
                ApprovalMode::Allow => {
                    rules.deny.retain(|item| item != prefix);
                    rules.allow.push(prefix.to_string());
                }
                ApprovalMode::Deny => {
                    rules.allow.retain(|item| item != prefix);
                    rules.deny.push(prefix.to_string());
                }
                ApprovalMode::Ask => {}
            }
            state
                .sirix_config_store
                .save_workspace_shell_rules(runtime.workspace_root.as_path(), &rules)
                .map_err(ApiError::internal)?;
        }
        "global" => {
            let mut rules = state
                .sirix_config_store
                .load_global_shell_rules()
                .map_err(ApiError::internal)?;
            match target_mode {
                ApprovalMode::Allow => {
                    rules.deny.retain(|item| item != prefix);
                    rules.allow.push(prefix.to_string());
                }
                ApprovalMode::Deny => {
                    rules.allow.retain(|item| item != prefix);
                    rules.deny.push(prefix.to_string());
                }
                ApprovalMode::Ask => {}
            }
            state
                .sirix_config_store
                .save_global_shell_rules(&rules)
                .map_err(ApiError::internal)?;
        }
        other => {
            return Err(ApiError::bad_request(format!(
                "unsupported shell rule scope {other}"
            )));
        }
    }

    reconfigure_ai_session_agent(
        &state,
        state.sirix_config_store.as_ref(),
        ai_session_id,
        runtime.agent_id.as_str(),
        None,
    )
    .await
    .map_err(ApiError::internal)?;

    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn resolve_session(
    State(state): State<AppState>,
    Query(query): Query<ResolveSessionQuery>,
) -> Result<Json<AiSessionRecord>, ApiError> {
    let session_id = uuid::Uuid::parse_str(&query.id)
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let Some(record) = state.ai_session_registry.resolve(session_id).await else {
        return Err(ApiError::not_found(format!(
            "ai session not found for id={}",
            query.id
        )));
    };
    Ok(Json(record))
}

pub async fn check_approval(
    State(state): State<AppState>,
    Json(payload): Json<CheckApprovalRequest>,
) -> Result<Json<CheckApprovalResponse>, ApiError> {
    let session_id = uuid::Uuid::parse_str(payload.session_id.trim())
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let capability_key = payload.capability_key.trim();
    if capability_key.is_empty() {
        return Err(ApiError::bad_request(
            "capability_key cannot be empty".to_string(),
        ));
    }

    let Some(record) = state.ai_session_registry.resolve(session_id).await else {
        return Err(ApiError::not_found(format!(
            "ai session not found for id={}",
            payload.session_id
        )));
    };
    let effective_agent_id = payload
        .agent_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(record.agent_id.as_str());

    if let Some(cached) = state
        .ai_approval_registry
        .resolve_for_check(record.ai_session_id, effective_agent_id, capability_key)
        .await
    {
        let outcome = match cached.decision {
            ApprovalDecision::Allow => "allow",
            ApprovalDecision::Deny => "deny",
        };
        return Ok(Json(CheckApprovalResponse {
            outcome: outcome.to_string(),
            configured_mode: ApprovalMode::Allow,
            cached: true,
        }));
    }

    let resolved = resolve_capability_mode(
        state.sirix_config_store.as_ref(),
        StdPath::new(&record.cwd),
        effective_agent_id,
        capability_key,
    )
    .map_err(ApiError::internal)?;
    let outcome = match resolved.configured_mode {
        ApprovalMode::Allow => "allow",
        ApprovalMode::Deny => "deny",
        ApprovalMode::Ask => {
            emit_approval_request_event(
                &state,
                &record,
                resolved.agent_id.as_str(),
                resolved.model_id.as_str(),
                capability_key,
                resolved.configured_mode.clone(),
            )
            .await;
            "ask"
        }
    };
    Ok(Json(CheckApprovalResponse {
        outcome: outcome.to_string(),
        configured_mode: resolved.configured_mode,
        cached: false,
    }))
}

pub async fn resolve_approval(
    State(state): State<AppState>,
    Json(payload): Json<ResolveApprovalRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let session_id = uuid::Uuid::parse_str(payload.session_id.trim())
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let capability_key = payload.capability_key.trim().to_string();
    if capability_key.is_empty() {
        return Err(ApiError::bad_request(
            "capability_key cannot be empty".to_string(),
        ));
    }
    let Some(record) = state.ai_session_registry.resolve(session_id).await else {
        return Err(ApiError::not_found(format!(
            "ai session not found for id={}",
            payload.session_id
        )));
    };
    let effective_agent_id = payload
        .agent_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(record.agent_id.as_str());

    state
        .ai_approval_registry
        .set(
            record.ai_session_id,
            effective_agent_id,
            &capability_key,
            ApprovalRecord {
                decision: payload.decision,
                scope: payload.scope,
            },
        )
        .await;
    state
        .ai_approval_registry
        .clear_pending(record.ai_session_id, effective_agent_id, &capability_key)
        .await;

    if record.mirrored_to_backend {
        sync_approval_to_backend(
            &state,
            record.ai_session_id,
            &capability_key,
            payload.decision,
            payload.scope,
        )
        .await
        .map_err(ApiError::internal)?;
    }

    let _ = state.local_events.send(
        serde_json::json!({
            "type": "ai.approval.resolved",
            "payload": {
                "ai_session_id": record.ai_session_id,
                "terminal_id": record.terminal_id,
                "agent_id": effective_agent_id,
                "capability_key": capability_key,
                "decision": match payload.decision {
                    ApprovalDecision::Allow => "allow",
                    ApprovalDecision::Deny => "deny",
                },
                "scope": match payload.scope {
                    ApprovalScope::Once => "once",
                    ApprovalScope::Session => "session",
                    ApprovalScope::Deny => "deny",
                },
            }
        })
        .to_string(),
    );

    Ok(Json(serde_json::json!({"ok": true})))
}

pub async fn proxy_compatible_models(
    Path(ai_session_id): Path<uuid::Uuid>,
    State(state): State<AppState>,
) -> Result<Json<JsonValue>, ApiError> {
    let (active_provider_id, providers) = state
        .ai_session_registry
        .resolve_session_providers(ai_session_id)
        .await
        .ok_or_else(|| {
            ApiError::not_found(format!(
                "providers not found for ai session {ai_session_id}"
            ))
        })?;

    Ok(Json(session_models_payload(
        &providers,
        active_provider_id.as_str(),
    )))
}

pub async fn proxy_compatible_responses(
    Path(ai_session_id): Path<uuid::Uuid>,
    State(state): State<AppState>,
    Json(payload): Json<JsonValue>,
) -> Result<Response, ApiError> {
    let requested_model = payload
        .get("model")
        .and_then(JsonValue::as_str)
        .unwrap_or_default();
    let session_providers = state
        .ai_session_registry
        .resolve_session_providers(ai_session_id)
        .await
        .map(|(_, providers)| providers)
        .ok_or_else(|| {
            ApiError::not_found(format!(
                "providers not found for ai session {ai_session_id}"
            ))
        })?;
    let requested_model_slug = resolve_session_picker_model(&session_providers, requested_model)
        .map(|(_, model)| model.id.clone())
        .unwrap_or_else(|| requested_model.to_string());
    let requested_alias_provider =
        resolve_session_picker_model(&session_providers, requested_model)
            .map(|(provider, _)| provider.clone());
    let runtime = state
        .ai_session_registry
        .resolve_runtime(ai_session_id)
        .await;
    let effective_model = runtime
        .as_ref()
        .and_then(|snapshot| {
            snapshot
                .fallback
                .primary_disabled_until
                .filter(|until| *until > chrono::Utc::now())
                .filter(|_| snapshot.fallback.primary_model_id == requested_model_slug)
                .map(|_| snapshot.fallback.fallback_model_id.clone())
        })
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| requested_model_slug.clone());
    let mut effective_payload = payload.clone();
    if effective_model != requested_model {
        effective_payload["model"] = JsonValue::String(effective_model.clone());
    }
    let provider = if effective_model == requested_model_slug {
        if let Some(provider) = requested_alias_provider.clone() {
            tracing::info!(
                "[SIRIX_MODEL_ROUTING] using alias-selected provider ai_session_id={} requested_model={} resolved_model={} provider_id={} provider_kind={:?}",
                ai_session_id,
                requested_model,
                requested_model_slug,
                provider.id,
                provider.kind,
            );
            provider
        } else {
            let provider = state
                .ai_session_registry
                .resolve_provider_for_model(ai_session_id, effective_model.as_str())
                .await
                .ok_or_else(|| {
                    ApiError::not_found(format!(
                        "provider not found for ai session {ai_session_id}"
                    ))
                })?;
            tracing::info!(
                "[SIRIX_MODEL_ROUTING] using slug-selected provider ai_session_id={} requested_model={} resolved_model={} provider_id={} provider_kind={:?}",
                ai_session_id,
                requested_model,
                effective_model,
                provider.id,
                provider.kind,
            );
            provider
        }
    } else {
        let provider = state
            .ai_session_registry
            .resolve_provider_for_model(ai_session_id, effective_model.as_str())
            .await
            .ok_or_else(|| {
                ApiError::not_found(format!("provider not found for ai session {ai_session_id}"))
            })?;
        tracing::info!(
            "[SIRIX_MODEL_ROUTING] using fallback-selected provider ai_session_id={} requested_model={} requested_slug={} fallback_model={} provider_id={} provider_kind={:?}",
            ai_session_id,
            requested_model,
            requested_model_slug,
            effective_model,
            provider.id,
            provider.kind,
        );
        provider
    };
    let result = match provider.kind {
        ProviderKind::OpenAiCompatible => {
            proxy_openai_compatible_responses(&provider, &effective_payload).await
        }
        ProviderKind::OpenAiResponses
        | ProviderKind::OpenAiCodexApi
        | ProviderKind::Gemini
        | ProviderKind::Anthropic => proxy_native_responses(&provider, &effective_payload).await,
        ProviderKind::OpenAiCodexOauth => {
            proxy_openai_codex_oauth_responses(&state, &provider, &effective_payload).await
        }
    };
    if result.is_ok() {
        let _ = state
            .ai_session_registry
            .record_primary_model_success(ai_session_id, requested_model_slug.as_str())
            .await;
    } else {
        let _ = state
            .ai_session_registry
            .record_primary_model_failure(ai_session_id, requested_model_slug.as_str())
            .await;
    }
    result
}

fn session_models_payload(providers: &[ProviderConfig], active_provider_id: &str) -> JsonValue {
    let mut ordered_providers = providers
        .iter()
        .filter(|provider| provider.enabled)
        .collect::<Vec<_>>();
    ordered_providers.sort_by_key(|provider| {
        (
            provider.id != active_provider_id,
            provider.name.to_ascii_lowercase(),
            provider.id.to_ascii_lowercase(),
        )
    });

    let duplicate_model_ids = duplicate_session_text_model_ids(providers);
    let mut seen_picker_model_ids = HashSet::<String>::new();
    let mut models = Vec::new();
    for provider in ordered_providers {
        for model in provider.models.iter() {
            if !model.enabled || !matches!(model.model_kind, ModelKind::Text) {
                continue;
            }
            let picker_model_id = session_picker_model_id(provider, model, &duplicate_model_ids);
            if !seen_picker_model_ids.insert(picker_model_id.clone()) {
                continue;
            }
            models.push(serde_json::json!({
                "id": picker_model_id,
                "display_name": model.display_name,
                "owned_by": provider.name,
                "model_id": model.id,
                "context_window": effective_model_context_window(provider, model),
                "supports_images": model.supports_images,
            }));
        }
    }

    serde_json::json!({ "data": models })
}

async fn proxy_openai_compatible_responses(
    provider: &ProviderConfig,
    payload: &JsonValue,
) -> Result<Response, ApiError> {
    let upstream_body = translate_responses_request_to_chat_completions(payload)
        .map_err(ApiError::bad_request_anyhow)?;
    let base_url = normalized_provider_base_url(provider).map_err(ApiError::internal)?;
    let upstream_url = compatible_chat_completions_url(&base_url).map_err(ApiError::internal)?;
    let mut headers = provider_request_headers(provider).map_err(ApiError::internal)?;
    headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
    headers.insert(
        reqwest::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );

    let upstream_response = reqwest::Client::new()
        .post(upstream_url)
        .headers(headers)
        .json(&upstream_body)
        .send()
        .await
        .map_err(|error| ApiError::internal(error.into()))?;
    let status = upstream_response.status();
    if !status.is_success() {
        let body = upstream_response.text().await.unwrap_or_default();
        return Err(ApiError::bad_gateway(format!(
            "compatible provider /chat/completions failed with status {status}: {body}"
        )));
    }

    let byte_stream = upstream_response.bytes_stream().eventsource();
    let stream = async_stream::stream! {
        let mut created_sent = false;
        let mut message_added_sent = false;
        let mut accumulator = ChatCompletionAccumulator::default();
        futures_util::pin_mut!(byte_stream);
        while let Some(event) = byte_stream.next().await {
            let Ok(event) = event else {
                break;
            };
            if event.data == "[DONE]" {
                break;
            }
            let Ok(chunk) = serde_json::from_str::<JsonValue>(&event.data) else {
                continue;
            };
            accumulator.capture_chunk(&chunk);
            if !created_sent {
                let created_payload = serde_json::json!({
                    "type": "response.created",
                    "response": {
                        "id": accumulator.response_id(),
                    }
                });
                yield Ok::<Event, Infallible>(sse_json_event("response.created", &created_payload));
                created_sent = true;
            }
            let text_deltas = accumulator.take_text_deltas();
            if !message_added_sent && !text_deltas.is_empty() {
                let payload = serde_json::json!({
                    "type": "response.output_item.added",
                    "item": accumulator.message_item_added(),
                });
                yield Ok::<Event, Infallible>(sse_json_event("response.output_item.added", &payload));
                message_added_sent = true;
            }
            for delta in text_deltas {
                let payload = serde_json::json!({
                    "type": "response.output_text.delta",
                    "delta": delta,
                });
                yield Ok::<Event, Infallible>(sse_json_event("response.output_text.delta", &payload));
            }
        }

        if let Some(message_item) = accumulator.final_message_item() {
            let payload = serde_json::json!({
                "type": "response.output_item.done",
                "item": message_item,
            });
            yield Ok::<Event, Infallible>(sse_json_event("response.output_item.done", &payload));
        }

        for tool_item in accumulator.final_tool_items() {
            let payload = serde_json::json!({
                "type": "response.output_item.done",
                "item": tool_item,
            });
            yield Ok::<Event, Infallible>(sse_json_event("response.output_item.done", &payload));
        }

        let completed_payload = serde_json::json!({
            "type": "response.completed",
            "response": {
                "id": accumulator.response_id(),
                "usage": accumulator.responses_usage_json(),
            }
        });
        yield Ok::<Event, Infallible>(sse_json_event("response.completed", &completed_payload));
    };

    let mut headers = AxumHeaderMap::new();
    headers.insert(
        CONTENT_TYPE,
        AxumHeaderValue::from_static("text/event-stream"),
    );
    Ok((headers, Sse::new(stream)).into_response())
}

async fn proxy_native_responses(
    provider: &ProviderConfig,
    payload: &JsonValue,
) -> Result<Response, ApiError> {
    let base_url = normalized_provider_base_url(provider).map_err(ApiError::internal)?;
    let mut upstream_url = base_url.clone();
    if !upstream_url.path().ends_with('/') {
        let next_path = format!("{}/", upstream_url.path());
        upstream_url.set_path(&next_path);
    }
    let upstream_url = upstream_url
        .join("responses")
        .map_err(|error| ApiError::internal(error.into()))?;
    let mut headers = provider_request_headers(provider).map_err(ApiError::internal)?;
    headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
    headers.insert(
        reqwest::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );

    let upstream_response = reqwest::Client::new()
        .post(upstream_url)
        .headers(headers)
        .json(payload)
        .send()
        .await
        .map_err(|error| ApiError::internal(error.into()))?;
    let status = upstream_response.status();
    if !status.is_success() {
        let body = upstream_response.text().await.unwrap_or_default();
        return Err(ApiError::bad_gateway(format!(
            "responses provider request failed with status {status}: {body}"
        )));
    }

    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "text/event-stream")
        .body(Body::from_stream(upstream_response.bytes_stream()))
        .map_err(|error| ApiError::internal(error.into()))
}

async fn proxy_openai_codex_oauth_responses(
    state: &AppState,
    provider: &ProviderConfig,
    payload: &JsonValue,
) -> Result<Response, ApiError> {
    let base_url = normalized_provider_base_url(provider).map_err(ApiError::internal)?;
    let upstream_url = responses_endpoint_url(&base_url).map_err(ApiError::internal)?;
    let auth_manager = provider_auth_manager(state.sirix_config_store.as_ref(), &provider.id)
        .map_err(ApiError::internal)?;
    let auth = auth_manager.auth().await.ok_or_else(|| {
        ApiError::bad_gateway(format!(
            "OpenAI Codex OAuth provider {} is not authenticated",
            provider.id
        ))
    })?;
    let headers =
        openai_codex_oauth_request_headers(provider, &auth).map_err(ApiError::internal)?;

    let (upstream_response, retried) =
        send_openai_codex_oauth_responses_request(upstream_url, headers, payload).await?;
    let upstream_response = if upstream_response.status() == reqwest::StatusCode::UNAUTHORIZED
        && auth_manager.refresh_token_from_authority().await.is_ok()
    {
        state.logger.warn(format!(
            "[OPENAI_AUTH] retrying responses after refresh provider_id={}",
            provider.id
        ));
        let refreshed_auth = auth_manager.auth().await.ok_or_else(|| {
            ApiError::bad_gateway(format!(
                "OpenAI Codex OAuth provider {} lost auth after refresh",
                provider.id
            ))
        })?;
        let headers = openai_codex_oauth_request_headers(provider, &refreshed_auth)
            .map_err(ApiError::internal)?;
        let (retry_response, _) = send_openai_codex_oauth_responses_request(
            responses_endpoint_url(
                &normalized_provider_base_url(provider).map_err(ApiError::internal)?,
            )
            .map_err(ApiError::internal)?,
            headers,
            payload,
        )
        .await?;
        retry_response
    } else {
        if retried {
            state.logger.warn(format!(
                "[OPENAI_AUTH] upstream returned unauthorized provider_id={}",
                provider.id
            ));
        }
        upstream_response
    };

    let status = upstream_response.status();
    if !status.is_success() {
        let body = upstream_response.text().await.unwrap_or_default();
        return Err(ApiError::bad_gateway(format!(
            "OpenAI Codex OAuth provider request failed with status {status}: {body}"
        )));
    }

    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "text/event-stream")
        .body(Body::from_stream(upstream_response.bytes_stream()))
        .map_err(|error| ApiError::internal(error.into()))
}

async fn send_openai_codex_oauth_responses_request(
    upstream_url: Url,
    headers: HeaderMap,
    payload: &JsonValue,
) -> Result<(reqwest::Response, bool), ApiError> {
    let upstream_response = reqwest::Client::new()
        .post(upstream_url)
        .headers(headers)
        .json(payload)
        .send()
        .await
        .map_err(|error| ApiError::internal(error.into()))?;
    let is_unauthorized = upstream_response.status() == reqwest::StatusCode::UNAUTHORIZED;
    Ok((upstream_response, is_unauthorized))
}

async fn fetch_provider_models(provider: &ProviderConfig) -> anyhow::Result<Vec<ModelConfig>> {
    let base_url = normalized_provider_base_url(provider)?;
    let models_url = provider_models_url(provider, &base_url)?;
    let headers = provider_request_headers(provider)?;

    let response = reqwest::Client::new()
        .get(models_url)
        .headers(headers)
        .send()
        .await?
        .error_for_status()?;
    let payload = response.json::<JsonValue>().await?;
    parse_provider_models(provider, &payload)
}

async fn discover_openai_codex_oauth_models(
    state: &AppState,
    provider: &ProviderConfig,
) -> anyhow::Result<Vec<ModelConfig>> {
    let auth_manager = provider_auth_manager(state.sirix_config_store.as_ref(), &provider.id)?;
    let auth = auth_manager.auth().await;
    let Some(auth) = auth else {
        return Ok(Vec::new());
    };

    let base_url = normalized_provider_base_url(provider)?;
    let mut models_url = base_url.clone();
    if !models_url.path().ends_with('/') {
        let next_path = format!("{}/", models_url.path());
        models_url.set_path(&next_path);
    }
    models_url = models_url.join("models")?;
    models_url
        .query_pairs_mut()
        .append_pair("client_version", env!("CARGO_PKG_VERSION"));

    let headers = openai_codex_oauth_model_headers(provider, &auth)?;
    let response = reqwest::Client::new()
        .get(models_url)
        .headers(headers)
        .send()
        .await?
        .error_for_status()?;
    let payload = response.json::<ModelsResponse>().await?;
    Ok(convert_openai_codex_model_infos(payload.models))
}

fn responses_endpoint_url(base_url: &Url) -> anyhow::Result<Url> {
    let mut upstream_url = base_url.clone();
    if !upstream_url.path().ends_with('/') {
        let next_path = format!("{}/", upstream_url.path());
        upstream_url.set_path(&next_path);
    }
    upstream_url.join("responses").map_err(Into::into)
}

fn openai_codex_oauth_request_headers(
    provider: &ProviderConfig,
    auth: &CodexAuth,
) -> anyhow::Result<HeaderMap> {
    let mut headers = parse_provider_headers_json(&provider.headers_json)?;
    headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
    headers.insert(
        reqwest::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );

    attach_openai_codex_oauth_auth_headers(&mut headers, auth)?;

    Ok(headers)
}

fn openai_codex_oauth_model_headers(
    provider: &ProviderConfig,
    auth: &CodexAuth,
) -> anyhow::Result<HeaderMap> {
    let mut headers = parse_provider_headers_json(&provider.headers_json)?;
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    attach_openai_codex_oauth_auth_headers(&mut headers, auth)?;
    Ok(headers)
}

fn attach_openai_codex_oauth_auth_headers(
    headers: &mut HeaderMap,
    auth: &CodexAuth,
) -> anyhow::Result<()> {
    headers
        .entry(HeaderName::from_static("version"))
        .or_insert(HeaderValue::from_static(env!("CARGO_PKG_VERSION")));

    let token = auth
        .get_token()
        .context("OpenAI Codex OAuth auth is missing access token")?;
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {token}"))
            .context("invalid authorization header value")?,
    );

    if let Some(account_id) = auth.get_account_id() {
        headers.insert(
            HeaderName::from_static("chatgpt-account-id"),
            HeaderValue::from_str(&account_id)
                .context("invalid chatgpt account id header value")?,
        );
    }
    Ok(())
}

fn convert_openai_codex_model_infos(models: Vec<ModelInfo>) -> Vec<ModelConfig> {
    let mut converted = models
        .into_iter()
        .filter(|model| model.visibility == ModelVisibility::List)
        .filter(|model| !model.slug.trim().is_empty())
        .map(|model| ModelConfig {
            id: model.slug.clone(),
            display_name: model.display_name.clone(),
            model_kind: ModelKind::Text,
            context_window: model
                .context_window
                .and_then(|value| u32::try_from(value).ok()),
            supports_images: model.input_modalities.contains(&InputModality::Image),
            enabled: true,
        })
        .collect::<Vec<_>>();

    converted.sort_by(|left, right| left.display_name.cmp(&right.display_name));
    converted.dedup_by(|left, right| left.id == right.id);
    converted
}

fn normalized_provider_base_url(provider: &ProviderConfig) -> anyhow::Result<Url> {
    let raw = provider.base_url.trim();
    let default_base = match provider.kind {
        ProviderKind::OpenAiCompatible
        | ProviderKind::OpenAiResponses
        | ProviderKind::OpenAiCodexApi => "https://api.openai.com/v1",
        ProviderKind::OpenAiCodexOauth => "https://chatgpt.com/backend-api/codex",
        ProviderKind::Gemini => "https://generativelanguage.googleapis.com/v1beta/openai",
        ProviderKind::Anthropic => "https://api.anthropic.com/v1",
    };
    let mut url = Url::parse(if raw.is_empty() { default_base } else { raw })?;
    let path = url.path().trim_end_matches('/');
    if path.is_empty() {
        let default_path = match provider.kind {
            ProviderKind::Gemini => "/v1beta/openai",
            ProviderKind::OpenAiCodexOauth => "/backend-api/codex",
            _ => "/v1",
        };
        url.set_path(default_path);
    }
    Ok(url)
}

fn provider_models_url(provider: &ProviderConfig, base_url: &Url) -> anyhow::Result<Url> {
    let base_host = base_url.host_str().unwrap_or_default();
    let mut api_root = base_url.clone();
    if !api_root.path().ends_with('/') {
        let next_path = format!("{}/", api_root.path());
        api_root.set_path(&next_path);
    }
    if base_host.contains("openrouter.ai") && resolved_provider_api_key(provider).is_some() {
        return Ok(api_root.join("models/user")?);
    }

    let mut url = api_root.join("models")?;
    if provider.kind == ProviderKind::Anthropic {
        url.query_pairs_mut().append_pair("limit", "1000");
    }
    Ok(url)
}

fn provider_request_headers(provider: &ProviderConfig) -> anyhow::Result<HeaderMap> {
    let mut headers = parse_provider_headers_json(&provider.headers_json)?;
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));

    match provider.kind {
        ProviderKind::Anthropic => {
            if let Some(api_key) = resolved_provider_api_key(provider) {
                headers
                    .entry(HeaderName::from_static("x-api-key"))
                    .or_insert(
                        HeaderValue::from_str(&api_key)
                            .context("invalid anthropic api key header value")?,
                    );
            }
            headers
                .entry(HeaderName::from_static("anthropic-version"))
                .or_insert(HeaderValue::from_static("2023-06-01"));
        }
        ProviderKind::OpenAiCompatible
        | ProviderKind::OpenAiResponses
        | ProviderKind::OpenAiCodexApi
        | ProviderKind::Gemini => {
            if let Some(api_key) = resolved_provider_api_key(provider) {
                headers.entry(AUTHORIZATION).or_insert(
                    HeaderValue::from_str(&format!("Bearer {api_key}"))
                        .context("invalid authorization header value")?,
                );
            }
        }
        ProviderKind::OpenAiCodexOauth => {}
    }

    Ok(headers)
}

fn resolved_provider_api_key(provider: &ProviderConfig) -> Option<String> {
    if !provider.api_key.trim().is_empty() {
        return Some(provider.api_key.trim().to_string());
    }

    let env_key = provider.api_key_env.trim();
    if env_key.is_empty() {
        return None;
    }

    std::env::var(env_key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn parse_provider_headers_json(raw: &str) -> anyhow::Result<HeaderMap> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed == "{}" {
        return Ok(HeaderMap::new());
    }

    let value = serde_json::from_str::<JsonValue>(trimmed)
        .with_context(|| "provider headers_json must be a JSON object".to_string())?;
    let object = value
        .as_object()
        .context("provider headers_json must decode to a JSON object")?;
    let mut headers = HeaderMap::new();
    for (key, value) in object {
        let header_name = HeaderName::from_bytes(key.as_bytes())
            .with_context(|| format!("invalid header name {key}"))?;
        let value_text = match value {
            JsonValue::String(value) => value.clone(),
            JsonValue::Bool(value) => value.to_string(),
            JsonValue::Number(value) => value.to_string(),
            JsonValue::Null => continue,
            _ => anyhow::bail!("header {key} must be a string, number, or boolean"),
        };
        let header_value = HeaderValue::from_str(&value_text)
            .with_context(|| format!("invalid header value for {key}"))?;
        headers.insert(header_name, header_value);
    }
    Ok(headers)
}

fn parse_provider_models(
    provider: &ProviderConfig,
    payload: &JsonValue,
) -> anyhow::Result<Vec<ModelConfig>> {
    let items = match payload {
        JsonValue::Object(map) => map
            .get("data")
            .and_then(JsonValue::as_array)
            .cloned()
            .unwrap_or_default(),
        JsonValue::Array(items) => items.clone(),
        _ => Vec::new(),
    };

    let mut models = Vec::new();
    for item in items {
        let Some(object) = item.as_object() else {
            continue;
        };
        let Some(id) = object
            .get("id")
            .and_then(JsonValue::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };

        models.push(ModelConfig {
            id: id.to_string(),
            display_name: object
                .get("display_name")
                .and_then(JsonValue::as_str)
                .or_else(|| object.get("name").and_then(JsonValue::as_str))
                .map(ToString::to_string)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| prettify_model_id(id)),
            model_kind: infer_model_kind(id, object),
            context_window: Some(infer_context_window(provider, id, object)),
            supports_images: infer_supports_images(provider, id, object),
            enabled: true,
        });
    }

    models.sort_by(|left, right| left.id.cmp(&right.id));
    models.dedup_by(|left, right| left.id == right.id);
    models.sort_by(|left, right| left.display_name.cmp(&right.display_name));
    Ok(models)
}

fn infer_model_kind(id: &str, object: &serde_json::Map<String, JsonValue>) -> ModelKind {
    let id_lower = id.to_ascii_lowercase();
    if id_lower.contains("embed") {
        return ModelKind::Embedding;
    }
    if id_lower.contains("whisper") || id_lower.contains("transcribe") || id_lower.contains("asr") {
        return ModelKind::Asr;
    }
    if id_lower.contains("tts") || id_lower.contains("speech") {
        return ModelKind::Tts;
    }
    if id_lower.contains("image")
        || id_lower.contains("dall-e")
        || id_lower.contains("gpt-image")
        || output_modalities(object)
            .iter()
            .any(|value| value == "image")
    {
        return ModelKind::ImageGeneration;
    }
    ModelKind::Text
}

fn infer_context_window(
    provider: &ProviderConfig,
    model_id: &str,
    object: &serde_json::Map<String, JsonValue>,
) -> u32 {
    for key in [
        "context_window",
        "context_length",
        "max_context_length",
        "input_token_limit",
        "max_input_tokens",
    ] {
        if let Some(value) = object
            .get(key)
            .and_then(JsonValue::as_u64)
            .and_then(|value| u32::try_from(value).ok())
        {
            return value;
        }
    }

    provider
        .default_context_window
        .unwrap_or_else(|| infer_provider_default_context_window(&provider.kind, model_id))
}

fn infer_supports_images(
    provider: &ProviderConfig,
    model_id: &str,
    object: &serde_json::Map<String, JsonValue>,
) -> bool {
    if object
        .get("supports_images")
        .and_then(JsonValue::as_bool)
        .unwrap_or(false)
        || object
            .get("vision")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false)
    {
        return true;
    }

    let input_modalities = input_modalities(object);
    if input_modalities.iter().any(|value| value == "image") {
        return true;
    }

    let model_id = model_id.to_ascii_lowercase();
    match provider.kind {
        ProviderKind::Anthropic => model_id.starts_with("claude"),
        ProviderKind::Gemini => model_id.starts_with("gemini"),
        ProviderKind::OpenAiResponses
        | ProviderKind::OpenAiCompatible
        | ProviderKind::OpenAiCodexOauth
        | ProviderKind::OpenAiCodexApi => [
            "gpt-4o",
            "gpt-4.1",
            "gpt-5",
            "computer-use",
            "vision",
            "vl",
            "gemini",
            "claude",
            "pixtral",
            "gemma-3",
        ]
        .iter()
        .any(|token| model_id.contains(token)),
    }
}

fn input_modalities(object: &serde_json::Map<String, JsonValue>) -> Vec<String> {
    object
        .get("architecture")
        .and_then(JsonValue::as_object)
        .and_then(|architecture| architecture.get("input_modalities"))
        .and_then(JsonValue::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(JsonValue::as_str)
                .map(|value| value.to_ascii_lowercase())
                .collect()
        })
        .unwrap_or_default()
}

fn output_modalities(object: &serde_json::Map<String, JsonValue>) -> Vec<String> {
    object
        .get("architecture")
        .and_then(JsonValue::as_object)
        .and_then(|architecture| architecture.get("output_modalities"))
        .and_then(JsonValue::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(JsonValue::as_str)
                .map(|value| value.to_ascii_lowercase())
                .collect()
        })
        .unwrap_or_default()
}

fn prettify_model_id(raw: &str) -> String {
    let trimmed = raw.trim();
    let tail = trimmed.rsplit('/').next().unwrap_or(trimmed);
    tail.split(['-', '_', '.'])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let upper = part.to_ascii_uppercase();
            if upper.len() <= 4 && upper.chars().all(|char| char.is_ascii_alphanumeric()) {
                return upper;
            }

            let mut chars = part.chars();
            let Some(first) = chars.next() else {
                return String::new();
            };
            let mut text = String::new();
            text.extend(first.to_uppercase());
            text.push_str(chars.as_str());
            text
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: String) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message,
        }
    }

    fn bad_request_anyhow(error: anyhow::Error) -> Self {
        Self::bad_request(error.to_string())
    }

    fn not_found(message: String) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message,
        }
    }

    pub(crate) fn internal(error: anyhow::Error) -> Self {
        Self {
            status: StatusCode::BAD_GATEWAY,
            message: error.to_string(),
        }
    }

    fn bad_gateway(message: String) -> Self {
        Self {
            status: StatusCode::BAD_GATEWAY,
            message,
        }
    }
}

#[derive(Default)]
struct ChatCompletionAccumulator {
    response_id: Option<String>,
    message_item_id: Option<String>,
    pending_text_deltas: Vec<String>,
    full_text: String,
    tool_calls: BTreeMap<usize, ChatCompletionToolCall>,
    usage: Option<JsonValue>,
}

#[derive(Default)]
struct ChatCompletionToolCall {
    id: String,
    name: String,
    arguments: String,
}

impl ChatCompletionAccumulator {
    fn capture_chunk(&mut self, chunk: &JsonValue) {
        if self.response_id.is_none() {
            self.response_id = chunk
                .get("id")
                .and_then(JsonValue::as_str)
                .map(ToString::to_string);
        }
        if let Some(usage) = chunk.get("usage").cloned() {
            self.usage = Some(usage);
        }
        let Some(choices) = chunk.get("choices").and_then(JsonValue::as_array) else {
            return;
        };
        for choice in choices {
            let Some(delta) = choice.get("delta").and_then(JsonValue::as_object) else {
                continue;
            };
            if let Some(text) = delta.get("content").and_then(JsonValue::as_str) {
                self.pending_text_deltas.push(text.to_string());
                self.full_text.push_str(text);
            }
            if let Some(tool_calls) = delta.get("tool_calls").and_then(JsonValue::as_array) {
                for tool_call in tool_calls {
                    let index = tool_call
                        .get("index")
                        .and_then(JsonValue::as_u64)
                        .and_then(|value| usize::try_from(value).ok())
                        .unwrap_or(0);
                    let entry = self.tool_calls.entry(index).or_default();
                    if let Some(id) = tool_call.get("id").and_then(JsonValue::as_str) {
                        entry.id = id.to_string();
                    }
                    if let Some(function) = tool_call.get("function").and_then(JsonValue::as_object)
                    {
                        if let Some(name) = function.get("name").and_then(JsonValue::as_str) {
                            entry.name = name.to_string();
                        }
                        if let Some(arguments) =
                            function.get("arguments").and_then(JsonValue::as_str)
                        {
                            entry.arguments.push_str(arguments);
                        }
                    }
                }
            }
        }
    }

    fn take_text_deltas(&mut self) -> Vec<String> {
        std::mem::take(&mut self.pending_text_deltas)
    }

    fn ensure_message_item_id(&mut self) -> String {
        if let Some(item_id) = self.message_item_id.clone() {
            return item_id;
        }
        let item_id = format!("msg_{}", self.response_id());
        self.message_item_id = Some(item_id.clone());
        item_id
    }

    fn message_item_added(&mut self) -> JsonValue {
        serde_json::json!({
            "type": "message",
            "role": "assistant",
            "id": self.ensure_message_item_id(),
            "content": [
                {
                    "type": "output_text",
                    "text": "",
                }
            ]
        })
    }

    fn final_message_item(&self) -> Option<JsonValue> {
        if self.full_text.is_empty() {
            return None;
        }
        Some(serde_json::json!({
            "type": "message",
            "role": "assistant",
            "id": self
                .message_item_id
                .clone()
                .unwrap_or_else(|| format!("msg_{}", self.response_id())),
            "content": [
                {
                    "type": "output_text",
                    "text": self.full_text,
                }
            ]
        }))
    }

    fn final_tool_items(&self) -> Vec<JsonValue> {
        self.tool_calls
            .values()
            .filter(|item| !item.name.trim().is_empty())
            .map(|item| {
                serde_json::json!({
                    "type": "function_call",
                    "name": item.name,
                    "arguments": item.arguments,
                    "call_id": if item.id.trim().is_empty() { format!("call_{}", item.name) } else { item.id.clone() },
                })
            })
            .collect()
    }

    fn response_id(&self) -> String {
        self.response_id
            .clone()
            .unwrap_or_else(|| "compat-response".to_string())
    }

    fn responses_usage_json(&self) -> JsonValue {
        let Some(usage) = self.usage.as_ref().and_then(JsonValue::as_object) else {
            return JsonValue::Null;
        };
        serde_json::json!({
            "input_tokens": usage.get("prompt_tokens").and_then(JsonValue::as_i64).unwrap_or(0),
            "input_tokens_details": {
                "cached_tokens": usage
                    .get("prompt_tokens_details")
                    .and_then(JsonValue::as_object)
                    .and_then(|details| details.get("cached_tokens"))
                    .and_then(JsonValue::as_i64)
                    .unwrap_or(0),
            },
            "output_tokens": usage.get("completion_tokens").and_then(JsonValue::as_i64).unwrap_or(0),
            "output_tokens_details": {
                "reasoning_tokens": usage
                    .get("completion_tokens_details")
                    .and_then(JsonValue::as_object)
                    .and_then(|details| details.get("reasoning_tokens"))
                    .and_then(JsonValue::as_i64)
                    .unwrap_or(0),
            },
            "total_tokens": usage.get("total_tokens").and_then(JsonValue::as_i64).unwrap_or(0),
        })
    }
}

fn compatible_chat_completions_url(base_url: &Url) -> anyhow::Result<Url> {
    let mut api_root = base_url.clone();
    if !api_root.path().ends_with('/') {
        let next_path = format!("{}/", api_root.path());
        api_root.set_path(&next_path);
    }
    Ok(api_root.join("chat/completions")?)
}

fn translate_responses_request_to_chat_completions(
    payload: &JsonValue,
) -> anyhow::Result<JsonValue> {
    let model = payload
        .get("model")
        .and_then(JsonValue::as_str)
        .filter(|value| !value.trim().is_empty())
        .context("responses request missing model")?;
    let mut messages = Vec::new();
    if let Some(instructions) = payload
        .get("instructions")
        .and_then(JsonValue::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        messages.push(serde_json::json!({
            "role": "system",
            "content": instructions,
        }));
    }

    for item in payload
        .get("input")
        .and_then(JsonValue::as_array)
        .into_iter()
        .flatten()
    {
        append_chat_messages_from_response_input(item, &mut messages);
    }

    let tools: Vec<JsonValue> = payload
        .get("tools")
        .and_then(JsonValue::as_array)
        .map(|tools| convert_responses_tools_to_chat_tools(tools))
        .unwrap_or_default();

    let mut request = serde_json::json!({
        "model": model,
        "messages": messages,
        "stream": true,
        "stream_options": {
            "include_usage": true,
        }
    });
    if !tools.is_empty() {
        request["tools"] = JsonValue::Array(tools);
        request["parallel_tool_calls"] = payload
            .get("parallel_tool_calls")
            .cloned()
            .unwrap_or(JsonValue::Bool(false));
        if let Some(tool_choice) = payload.get("tool_choice").cloned() {
            request["tool_choice"] = tool_choice;
        }
    }
    Ok(request)
}

fn append_chat_messages_from_response_input(item: &JsonValue, messages: &mut Vec<JsonValue>) {
    let Some(item_type) = item.get("type").and_then(JsonValue::as_str) else {
        return;
    };
    match item_type {
        "message" => {
            let role = item
                .get("role")
                .and_then(JsonValue::as_str)
                .unwrap_or("user");
            // Many OpenAI-compatible chat-completions providers only accept the
            // legacy role set (`system`/`user`/`assistant`/`tool`/`function`)
            // and reject Responses-style `developer`. Sirix uses the local
            // `/responses` proxy for every session, so downgrade `developer`
            // to `system` during the compatibility translation step.
            let chat_role = if role == "developer" { "system" } else { role };
            let content = chat_content_from_response_message(item.get("content"));
            messages.push(serde_json::json!({
                "role": chat_role,
                "content": content,
            }));
        }
        "function_call" => {
            let name = item
                .get("name")
                .and_then(JsonValue::as_str)
                .unwrap_or_default();
            let arguments = item
                .get("arguments")
                .and_then(JsonValue::as_str)
                .unwrap_or("{}");
            let call_id = item
                .get("call_id")
                .and_then(JsonValue::as_str)
                .unwrap_or(name);
            messages.push(serde_json::json!({
                "role": "assistant",
                "content": "",
                "tool_calls": [
                    {
                        "id": call_id,
                        "type": "function",
                        "function": {
                            "name": name,
                            "arguments": arguments,
                        }
                    }
                ]
            }));
        }
        "function_call_output" | "custom_tool_call_output" | "mcp_tool_call_output" => {
            let call_id = item
                .get("call_id")
                .and_then(JsonValue::as_str)
                .unwrap_or_default();
            let output = response_output_payload_to_text(item.get("output"));
            messages.push(serde_json::json!({
                "role": "tool",
                "tool_call_id": call_id,
                "content": output,
            }));
        }
        _ => {}
    }
}

fn chat_content_from_response_message(content: Option<&JsonValue>) -> JsonValue {
    let mut parts = Vec::new();
    for item in content.and_then(JsonValue::as_array).into_iter().flatten() {
        let Some(item_type) = item.get("type").and_then(JsonValue::as_str) else {
            continue;
        };
        match item_type {
            "input_text" | "output_text" => {
                if let Some(text) = item.get("text").and_then(JsonValue::as_str) {
                    parts.push(serde_json::json!({
                        "type": "text",
                        "text": text,
                    }));
                }
            }
            "input_image" => {
                if let Some(image_url) = item.get("image_url").and_then(JsonValue::as_str) {
                    parts.push(serde_json::json!({
                        "type": "image_url",
                        "image_url": {
                            "url": image_url,
                        }
                    }));
                }
            }
            _ => {}
        }
    }
    JsonValue::Array(parts)
}

fn response_output_payload_to_text(payload: Option<&JsonValue>) -> String {
    let Some(payload) = payload else {
        return String::new();
    };
    match payload {
        JsonValue::String(value) => value.clone(),
        JsonValue::Array(items) => items
            .iter()
            .filter_map(|item| item.get("text").and_then(JsonValue::as_str))
            .collect::<Vec<_>>()
            .join(""),
        _ => payload.to_string(),
    }
}

fn convert_responses_tools_to_chat_tools(tools: &[JsonValue]) -> Vec<JsonValue> {
    let mut converted = Vec::new();
    for tool in tools {
        convert_single_response_tool(tool, &mut converted);
    }
    converted
}

fn convert_single_response_tool(tool: &JsonValue, converted: &mut Vec<JsonValue>) {
    let Some(tool_type) = tool.get("type").and_then(JsonValue::as_str) else {
        return;
    };
    match tool_type {
        "function" => {
            let Some(name) = tool.get("name").and_then(JsonValue::as_str) else {
                return;
            };
            let parameters = tool
                .get("parameters")
                .cloned()
                .or_else(|| tool.get("input_schema").cloned())
                .unwrap_or_else(|| {
                    serde_json::json!({
                        "type": "object",
                        "properties": {},
                        "additionalProperties": true,
                    })
                });
            converted.push(serde_json::json!({
                "type": "function",
                "function": {
                    "name": name,
                    "description": tool.get("description").cloned().unwrap_or(JsonValue::String(String::new())),
                    "parameters": parameters,
                }
            }));
        }
        "namespace" => {
            if let Some(items) = tool.get("tools").and_then(JsonValue::as_array) {
                for item in items {
                    convert_single_response_tool(item, converted);
                }
            }
        }
        _ => {}
    }
}

fn sse_json_event(kind: &str, payload: &JsonValue) -> Event {
    Event::default().event(kind).data(payload.to_string())
}

fn resolve_capability_mode(
    store: &crate::app::ai::config::SirixConfigStore,
    cwd: &StdPath,
    agent_id: &str,
    capability_key: &str,
) -> anyhow::Result<ResolvedCapabilityApproval> {
    let config = store.effective_for_workspace(cwd.to_str())?.config;
    let agent = config
        .agents
        .iter()
        .find(|item| item.id == agent_id)
        .cloned();
    let Some(agent) = agent else {
        return Ok(ResolvedCapabilityApproval {
            agent_id: agent_id.to_string(),
            model_id: String::new(),
            configured_mode: ApprovalMode::Allow,
        });
    };

    let configured_mode = if capability_key == "builtin.shell" {
        resolve_shell_capability_mode(store, cwd, &agent)?
    } else if capability_key.starts_with("builtin.") || capability_key.starts_with("mcp.") {
        resolve_tool_capability_mode(store, cwd, &agent, capability_key)?
    } else {
        ApprovalMode::Allow
    };

    Ok(ResolvedCapabilityApproval {
        agent_id: agent.id,
        model_id: agent.model_id,
        configured_mode,
    })
}

struct ResolvedCapabilityApproval {
    agent_id: String,
    model_id: String,
    configured_mode: ApprovalMode,
}

fn resolve_shell_capability_mode(
    store: &crate::app::ai::config::SirixConfigStore,
    cwd: &StdPath,
    agent: &crate::app::ai::config::AgentConfig,
) -> anyhow::Result<ApprovalMode> {
    // Shell commands are evaluated later against prefix rules in the generated
    // exec-policy file. This API endpoint only needs the merged fallback mode
    // (`allow / ask / deny`) that applies when no prefix rule matches.
    Ok(match agent.approval_mode {
        ApprovalMode::Allow => ApprovalMode::Allow,
        ApprovalMode::Deny => ApprovalMode::Deny,
        ApprovalMode::Ask => {
            store
                .effective_shell_rules_for_agent(cwd, agent, &ShellRulesConfig::default())?
                .mode
        }
    })
}

fn resolve_tool_capability_mode(
    store: &crate::app::ai::config::SirixConfigStore,
    cwd: &StdPath,
    agent: &crate::app::ai::config::AgentConfig,
    capability_key: &str,
) -> anyhow::Result<ApprovalMode> {
    let rules = store.effective_tool_rules_for_agent(cwd, agent)?;
    if rules
        .deny
        .iter()
        .any(|rule| tool_rule_matches(rule, capability_key))
    {
        return Ok(ApprovalMode::Deny);
    }
    if rules
        .allow
        .iter()
        .any(|rule| tool_rule_matches(rule, capability_key))
    {
        return Ok(ApprovalMode::Allow);
    }
    Ok(rules.mode)
}

fn tool_rule_matches(rule: &str, capability_key: &str) -> bool {
    let normalized_rule = rule.trim();
    if normalized_rule.is_empty() {
        return false;
    }

    // Backward compatibility for existing builtin rules that only stored the
    // bare builtin tool id (for example `apply_patch`) before MCP capability
    // keys were added to the same rule set.
    if let Some(builtin_tool_id) = capability_key.strip_prefix("builtin.") {
        if normalized_rule.eq_ignore_ascii_case(builtin_tool_id) {
            return true;
        }
    }

    capability_rule_prefix_matches(normalized_rule, capability_key)
}

fn capability_rule_prefix_matches(rule: &str, capability_key: &str) -> bool {
    let rule = rule.trim().trim_matches('.');
    let capability_key = capability_key.trim().trim_matches('.');
    if rule.is_empty() || capability_key.is_empty() {
        return false;
    }

    if rule.eq_ignore_ascii_case(capability_key) {
        return true;
    }

    capability_key.len() > rule.len()
        && capability_key[..rule.len()].eq_ignore_ascii_case(rule)
        && capability_key.as_bytes()[rule.len()] == b'.'
}

async fn emit_approval_request_event(
    state: &AppState,
    record: &AiSessionRecord,
    agent_id: &str,
    model_id: &str,
    capability_key: &str,
    configured_mode: ApprovalMode,
) {
    if !state
        .ai_approval_registry
        .mark_pending(record.ai_session_id, agent_id, capability_key)
        .await
    {
        return;
    }

    let _ = state.local_events.send(
        serde_json::json!({
            "type": "ai.approval.request",
            "payload": {
                "ai_session_id": record.ai_session_id,
                "terminal_id": record.terminal_id,
                "cwd": record.cwd,
                "agent_id": agent_id,
                "model_id": model_id,
                "capability_key": capability_key,
                "configured_mode": configured_mode,
            }
        })
        .to_string(),
    );
}

async fn sync_approval_to_backend(
    state: &AppState,
    ai_session_id: uuid::Uuid,
    capability_key: &str,
    decision: ApprovalDecision,
    scope: ApprovalScope,
) -> anyhow::Result<()> {
    let Some(session) = state.auth_session_store.current_session().await else {
        return Ok(());
    };
    let url = format!(
        "{}/api/v1/ai-sessions/{}/approvals",
        state.config.backend.base_url.trim_end_matches('/'),
        ai_session_id
    );
    reqwest::Client::new()
        .post(url)
        .bearer_auth(session.access_token)
        .json(&serde_json::json!({
            "capability_key": capability_key,
            "decision": match decision {
                ApprovalDecision::Allow => "allow",
                ApprovalDecision::Deny => "deny",
            },
            "scope": match scope {
                ApprovalScope::Once => "once",
                ApprovalScope::Session => "session",
                ApprovalScope::Deny => "deny",
            },
        }))
        .send()
        .await?
        .error_for_status()?;
    Ok(())
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (
            self.status,
            Json(serde_json::json!({
                "error": self.message,
            })),
        )
            .into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider(kind: ProviderKind, base_url: &str) -> ProviderConfig {
        ProviderConfig {
            id: "provider".to_string(),
            name: "Provider".to_string(),
            kind,
            default_context_window: None,
            base_url: base_url.to_string(),
            api_key_env: String::new(),
            api_key: String::new(),
            headers_json: "{}".to_string(),
            enabled: true,
            models: Vec::new(),
        }
    }

    #[test]
    fn normalizes_empty_openai_base_url() {
        let provider = provider(ProviderKind::OpenAiResponses, "");
        let url = normalized_provider_base_url(&provider).expect("url should normalize");
        assert_eq!(url.as_str(), "https://api.openai.com/v1");
    }

    #[test]
    fn trailing_slash_base_url_keeps_compatible_models_and_responses_joinable() {
        let provider = provider(ProviderKind::OpenAiCompatible, "https://example.com/v1/");
        let base_url = normalized_provider_base_url(&provider).expect("url should normalize");
        let models_url = provider_models_url(&provider, &base_url).expect("models url should join");
        let responses_url =
            compatible_chat_completions_url(&base_url).expect("chat completions url should join");

        assert_eq!(models_url.as_str(), "https://example.com/v1/models");
        assert_eq!(
            responses_url.as_str(),
            "https://example.com/v1/chat/completions"
        );
    }

    #[test]
    fn parses_openai_style_model_payload() {
        let provider = provider(ProviderKind::OpenAiResponses, "https://api.openai.com/v1");
        let payload = serde_json::json!({
            "data": [
                { "id": "gpt-5", "owned_by": "openai" },
                { "id": "text-embedding-3-large", "owned_by": "openai" }
            ]
        });

        let models = parse_provider_models(&provider, &payload).expect("models should parse");

        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "gpt-5");
        assert!(models[0].supports_images);
        assert_eq!(models[1].model_kind, ModelKind::Embedding);
    }

    #[test]
    fn parses_openrouter_payload_with_modalities() {
        let provider = provider(
            ProviderKind::OpenAiCompatible,
            "https://openrouter.ai/api/v1",
        );
        let payload = serde_json::json!({
            "data": [
                {
                    "id": "openai/gpt-4.1",
                    "name": "GPT-4.1",
                    "context_length": 1048576,
                    "architecture": {
                        "input_modalities": ["text", "image"],
                        "output_modalities": ["text"]
                    }
                }
            ]
        });

        let models = parse_provider_models(&provider, &payload).expect("models should parse");

        assert_eq!(models.len(), 1);
        assert_eq!(models[0].display_name, "GPT-4.1");
        assert_eq!(models[0].context_window, Some(1_048_576));
        assert!(models[0].supports_images);
    }

    #[test]
    fn compat_accumulator_emits_stable_message_item_identity() {
        let mut accumulator = ChatCompletionAccumulator::default();
        accumulator.capture_chunk(&serde_json::json!({
            "id": "chatcmpl-1",
            "choices": [
                {
                    "delta": {
                        "content": "Hi"
                    }
                }
            ]
        }));

        let added = accumulator.message_item_added();
        let done = accumulator
            .final_message_item()
            .expect("message item should exist");

        assert_eq!(added.get("id"), done.get("id"));
        assert_eq!(
            done.pointer("/content/0/text").and_then(JsonValue::as_str),
            Some("Hi")
        );
    }

    #[test]
    fn compatibility_translation_maps_developer_role_to_system() {
        let payload = serde_json::json!({
            "model": "glm-5",
            "input": [
                {
                    "type": "message",
                    "role": "developer",
                    "content": [
                        {
                            "type": "input_text",
                            "text": "stay focused"
                        }
                    ]
                }
            ]
        });

        let translated = translate_responses_request_to_chat_completions(&payload)
            .expect("compatibility translation should succeed");
        let messages = translated
            .get("messages")
            .and_then(JsonValue::as_array)
            .expect("translated request should contain messages");

        assert_eq!(
            messages[0].get("role").and_then(JsonValue::as_str),
            Some("system")
        );
    }

    #[test]
    fn session_models_payload_keeps_provider_scoped_duplicate_ids() {
        let mut active = provider(ProviderKind::OpenAiCompatible, "https://example.com/v1");
        active.id = "glm".to_string();
        active.name = "GLM".to_string();
        active.models = vec![ModelConfig {
            id: "shared-model".to_string(),
            display_name: "GLM Shared".to_string(),
            model_kind: ModelKind::Text,
            context_window: Some(128_000),
            supports_images: false,
            enabled: true,
        }];

        let mut secondary = provider(ProviderKind::OpenAiResponses, "https://api.openai.com/v1");
        secondary.id = "openai".to_string();
        secondary.name = "OpenAI".to_string();
        secondary.models = vec![
            ModelConfig {
                id: "gpt-5".to_string(),
                display_name: "GPT-5".to_string(),
                model_kind: ModelKind::Text,
                context_window: Some(400_000),
                supports_images: true,
                enabled: true,
            },
            ModelConfig {
                id: "shared-model".to_string(),
                display_name: "OpenAI Shared".to_string(),
                model_kind: ModelKind::Text,
                context_window: Some(400_000),
                supports_images: true,
                enabled: true,
            },
        ];

        let payload = session_models_payload(&[secondary, active], "glm");
        let data = payload
            .get("data")
            .and_then(JsonValue::as_array)
            .expect("session model payload should contain data");

        assert_eq!(data.len(), 3);
        assert_eq!(
            data[0].get("id").and_then(JsonValue::as_str),
            Some("shared-model @ glm")
        );
        assert_eq!(
            data[0].get("owned_by").and_then(JsonValue::as_str),
            Some("GLM")
        );
        assert_eq!(data[1].get("id").and_then(JsonValue::as_str), Some("gpt-5"));
        assert_eq!(
            data[2].get("id").and_then(JsonValue::as_str),
            Some("shared-model @ openai")
        );
    }
}
