use std::path::PathBuf;

use anyhow::Context;
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use reqwest::{
    header::{HeaderMap, HeaderName, HeaderValue, ACCEPT, AUTHORIZATION},
    Url,
};
use serde::Deserialize;
use serde_json::Value as JsonValue;

use crate::app::{
    ai::{
        approval::{ApprovalDecision, ApprovalRecord, ApprovalScope},
        config::{
            validate_sirix_config, ApprovalMode, ModelConfig, ModelKind, ProviderConfig,
            ProviderKind, SirixConfig,
        },
        session::{
            launch_ai_session, launch_ai_session_in_current_terminal, AiSessionLaunchResponse,
            AiSessionRecord,
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
}

#[derive(Debug, Deserialize)]
pub struct ResolveApprovalRequest {
    pub session_id: String,
    pub capability_key: String,
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
    validate_sirix_config(&payload).map_err(ApiError::bad_request_anyhow)?;
    state
        .sirix_config_store
        .save_global(&payload)
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

pub async fn discover_provider_models(
    Json(provider): Json<ProviderConfig>,
) -> Result<Json<ProviderModelsResponse>, ApiError> {
    let models = fetch_provider_models(&provider)
        .await
        .map_err(ApiError::internal)?;
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

    if let Some(cached) = state
        .ai_approval_registry
        .resolve_for_check(record.ai_session_id, capability_key)
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

    let configured_mode = resolve_capability_mode(
        state.sirix_config_store.as_ref(),
        &record.cwd,
        &record.agent_id,
        capability_key,
    )
    .map_err(ApiError::internal)?;
    let outcome = match configured_mode {
        ApprovalMode::Allow => "allow",
        ApprovalMode::Deny => "deny",
        ApprovalMode::AskOnce | ApprovalMode::AskEachTime => {
            emit_approval_request_event(&state, &record, capability_key, configured_mode.clone())
                .await;
            "ask"
        }
    };
    Ok(Json(CheckApprovalResponse {
        outcome: outcome.to_string(),
        configured_mode,
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

    state
        .ai_approval_registry
        .set(
            record.ai_session_id,
            capability_key.clone(),
            ApprovalRecord {
                decision: payload.decision,
                scope: payload.scope,
            },
        )
        .await;
    state
        .ai_approval_registry
        .clear_pending(record.ai_session_id, &capability_key)
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

fn normalized_provider_base_url(provider: &ProviderConfig) -> anyhow::Result<Url> {
    let raw = provider.base_url.trim();
    let default_base = match provider.kind {
        ProviderKind::OpenAiCompatible | ProviderKind::OpenAiResponses => {
            "https://api.openai.com/v1"
        }
        ProviderKind::Gemini => "https://generativelanguage.googleapis.com/v1beta/openai",
        ProviderKind::Anthropic => "https://api.anthropic.com/v1",
    };
    let mut url = Url::parse(if raw.is_empty() { default_base } else { raw })?;
    let path = url.path().trim_end_matches('/');
    if path.is_empty() {
        let default_path = match provider.kind {
            ProviderKind::Gemini => "/v1beta/openai",
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
        ProviderKind::OpenAiCompatible | ProviderKind::OpenAiResponses | ProviderKind::Gemini => {
            if let Some(api_key) = resolved_provider_api_key(provider) {
                headers.entry(AUTHORIZATION).or_insert(
                    HeaderValue::from_str(&format!("Bearer {api_key}"))
                        .context("invalid authorization header value")?,
                );
            }
        }
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
            context_window: infer_context_window(provider, id, object),
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

    match provider.kind {
        ProviderKind::Anthropic => 200_000,
        ProviderKind::Gemini => 1_048_576,
        ProviderKind::OpenAiResponses if model_id.starts_with("gpt-5") => 400_000,
        ProviderKind::OpenAiResponses => 200_000,
        ProviderKind::OpenAiCompatible => 128_000,
    }
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
        ProviderKind::OpenAiResponses | ProviderKind::OpenAiCompatible => [
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

    fn internal(error: anyhow::Error) -> Self {
        Self {
            status: StatusCode::BAD_GATEWAY,
            message: error.to_string(),
        }
    }
}

fn resolve_capability_mode(
    store: &crate::app::ai::config::SirixConfigStore,
    cwd: &str,
    agent_id: &str,
    capability_key: &str,
) -> anyhow::Result<ApprovalMode> {
    let config = store.effective_for_workspace(Some(cwd))?.config;
    let agent = config
        .agents
        .iter()
        .find(|item| item.id == agent_id)
        .cloned();
    let Some(agent) = agent else {
        return Ok(ApprovalMode::Allow);
    };

    for rule in &agent.capability_rules {
        if rule.key == capability_key {
            return Ok(rule.approval_mode.clone());
        }
    }
    Ok(ApprovalMode::Allow)
}

async fn emit_approval_request_event(
    state: &AppState,
    record: &AiSessionRecord,
    capability_key: &str,
    configured_mode: ApprovalMode,
) {
    if !state
        .ai_approval_registry
        .mark_pending(record.ai_session_id, capability_key)
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
                "agent_id": record.agent_id,
                "model_id": record.model_id,
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
        assert_eq!(models[0].context_window, 1_048_576);
        assert!(models[0].supports_images);
    }
}
