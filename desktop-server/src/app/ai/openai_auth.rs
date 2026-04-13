use std::{collections::HashMap, fs, sync::Arc};

use anyhow::Context;
use codex_config::types::AuthCredentialsStoreMode;
use codex_login::{
    run_login_server, save_auth, AuthDotJson, AuthManager, ServerOptions, ShutdownHandle, CLIENT_ID,
};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::app::{ai::config::SirixConfigStore, runtime_logger::RuntimeLogger};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenAiAuthStatus {
    pub provider_id: String,
    pub authenticated: bool,
    pub auth_mode: Option<String>,
    pub email: Option<String>,
    pub plan_type: Option<String>,
    pub account_id: Option<String>,
    pub login_in_progress: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StartOpenAiAuthResponse {
    pub provider_id: String,
    pub login_id: String,
    pub auth_url: String,
}

#[derive(Debug)]
struct ActiveBrowserLogin {
    login_id: String,
    shutdown_handle: ShutdownHandle,
}

#[derive(Debug, Default)]
pub struct OpenAiAuthRegistry {
    active_logins: Mutex<HashMap<String, ActiveBrowserLogin>>,
}

impl OpenAiAuthRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn status(
        &self,
        config_store: &SirixConfigStore,
        provider_id: &str,
    ) -> anyhow::Result<OpenAiAuthStatus> {
        let provider_id = normalize_provider_id(provider_id)?;
        let auth_manager = provider_auth_manager(config_store, provider_id)?;
        let auth = auth_manager.auth().await;
        let active_logins = self.active_logins.lock().await;

        // 状态接口统一从 provider 专属 auth home 读取认证信息。
        // 这样 Desktop App 同时展示多个 Codex OAuth provider 时，不会互相串状态。
        Ok(OpenAiAuthStatus {
            provider_id: provider_id.to_string(),
            authenticated: auth.is_some(),
            auth_mode: auth
                .as_ref()
                .and_then(|item| serde_json::to_value(item.api_auth_mode()).ok())
                .and_then(|value| value.as_str().map(str::to_string)),
            email: auth.as_ref().and_then(|item| item.get_account_email()),
            plan_type: auth.as_ref().and_then(|item| {
                item.account_plan_type()
                    .and_then(|plan| serde_json::to_value(plan).ok())
                    .and_then(|value| value.as_str().map(str::to_string))
            }),
            account_id: auth.as_ref().and_then(|item| item.get_account_id()),
            login_in_progress: active_logins.contains_key(provider_id),
        })
    }

    pub async fn start_browser_login(
        self: &Arc<Self>,
        config_store: &SirixConfigStore,
        provider_id: &str,
        logger: Arc<RuntimeLogger>,
    ) -> anyhow::Result<StartOpenAiAuthResponse> {
        let provider_id = normalize_provider_id(provider_id)?.to_string();
        let auth_home = config_store.provider_openai_auth_home(provider_id.as_str());
        fs::create_dir_all(&auth_home)
            .with_context(|| format!("failed to create {}", auth_home.display()))?;

        let mut options = ServerOptions::new(
            auth_home,
            CLIENT_ID.to_string(),
            None,
            AuthCredentialsStoreMode::File,
        );
        // Sirix 负责在 Desktop App 中调起浏览器，因此登录服务只返回 URL，
        // 不让 vendored Codex login 代码自行直接打开浏览器。
        options.open_browser = false;
        // 使用随机可用端口，避免多个 provider 或历史残留登录流程抢占固定 1455 端口。
        options.port = 0;

        let server = run_login_server(options).context("failed to start OpenAI login server")?;
        let login_id = Uuid::new_v4().to_string();
        let response_login_id = login_id.clone();
        let auth_url = server.auth_url.clone();
        let shutdown_handle = server.cancel_handle();

        if let Some(previous) = self.active_logins.lock().await.insert(
            provider_id.clone(),
            ActiveBrowserLogin {
                login_id: login_id.clone(),
                shutdown_handle: shutdown_handle.clone(),
            },
        ) {
            previous.shutdown_handle.shutdown();
        }

        let registry = Arc::clone(self);
        let provider_id_for_task = provider_id.clone();
        let login_id_for_task = login_id.clone();
        tokio::spawn(async move {
            let result = server.block_until_done().await;
            match result {
                Ok(()) => logger.info(format!(
                    "[OPENAI_AUTH] browser login completed provider_id={provider_id_for_task}"
                )),
                Err(error) => logger.warn(format!(
                    "[OPENAI_AUTH] browser login ended provider_id={provider_id_for_task} error={error}"
                )),
            }

            let mut active = registry.active_logins.lock().await;
            if active
                .get(provider_id_for_task.as_str())
                .is_some_and(|item| item.login_id == login_id_for_task)
            {
                active.remove(provider_id_for_task.as_str());
            }
        });

        Ok(StartOpenAiAuthResponse {
            provider_id,
            login_id: response_login_id,
            auth_url,
        })
    }

    pub async fn logout(
        &self,
        config_store: &SirixConfigStore,
        provider_id: &str,
    ) -> anyhow::Result<()> {
        let provider_id = normalize_provider_id(provider_id)?;
        self.cancel_active_login(provider_id).await;
        let auth_manager = provider_auth_manager(config_store, provider_id)?;
        auth_manager
            .logout()
            .context("failed to clear provider auth state")?;
        Ok(())
    }

    pub async fn import_auth_json(
        &self,
        config_store: &SirixConfigStore,
        provider_id: &str,
        payload: JsonValue,
    ) -> anyhow::Result<()> {
        let provider_id = normalize_provider_id(provider_id)?;
        self.cancel_active_login(provider_id).await;

        let auth_json = extract_import_auth_json(payload)?;
        validate_imported_auth_json(&auth_json)?;

        let auth_home = config_store.provider_openai_auth_home(provider_id);
        fs::create_dir_all(&auth_home)
            .with_context(|| format!("failed to create {}", auth_home.display()))?;

        // 这里保留导入 JSON 的完整 ChatGPT token 结构，确保 refresh_token /
        // last_refresh 等字段都能沿用 Codex 自己的 auth 生命周期逻辑。
        save_auth(&auth_home, &auth_json, AuthCredentialsStoreMode::File)
            .context("failed to persist imported OpenAI auth JSON")?;

        // 导入后立刻回读一次，提前暴露结构不兼容或 JWT 解析失败的问题，
        // 避免用户直到真正发请求时才发现导入内容不可用。
        let _ = provider_auth_manager(config_store, provider_id)?
            .auth()
            .await
            .context("imported OpenAI auth JSON could not be loaded")?;

        Ok(())
    }

    async fn cancel_active_login(&self, provider_id: &str) {
        if let Some(active) = self.active_logins.lock().await.remove(provider_id) {
            active.shutdown_handle.shutdown();
        }
    }
}

pub fn provider_auth_manager(
    config_store: &SirixConfigStore,
    provider_id: &str,
) -> anyhow::Result<Arc<AuthManager>> {
    let provider_id = normalize_provider_id(provider_id)?;
    Ok(AuthManager::shared(
        config_store.provider_openai_auth_home(provider_id),
        false,
        AuthCredentialsStoreMode::File,
    ))
}

fn normalize_provider_id(provider_id: &str) -> anyhow::Result<&str> {
    let provider_id = provider_id.trim();
    if provider_id.is_empty() {
        anyhow::bail!("provider_id cannot be empty");
    }
    Ok(provider_id)
}

fn extract_import_auth_json(payload: JsonValue) -> anyhow::Result<AuthDotJson> {
    let raw = match payload {
        JsonValue::Object(mut object) => object
            .remove("auth_json")
            .unwrap_or(JsonValue::Object(object)),
        other => other,
    };
    serde_json::from_value(raw).context("invalid OpenAI auth JSON payload")
}

fn validate_imported_auth_json(auth_json: &AuthDotJson) -> anyhow::Result<()> {
    if auth_json.openai_api_key.is_some() {
        anyhow::bail!("imported auth JSON must contain ChatGPT tokens instead of OPENAI_API_KEY");
    }

    let tokens = auth_json
        .tokens
        .as_ref()
        .context("imported auth JSON is missing tokens")?;
    if tokens.access_token.trim().is_empty() {
        anyhow::bail!("imported auth JSON is missing access_token");
    }
    if tokens.id_token.raw_jwt.trim().is_empty() {
        anyhow::bail!("imported auth JSON is missing id_token");
    }

    let account_id = tokens
        .account_id
        .as_deref()
        .or(tokens.id_token.chatgpt_account_id.as_deref())
        .unwrap_or_default()
        .trim()
        .to_string();
    if account_id.is_empty() {
        anyhow::bail!("imported auth JSON is missing ChatGPT account_id");
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};

    fn fake_jwt(account_id: &str) -> String {
        let header = URL_SAFE_NO_PAD.encode(r#"{"alg":"RS256","typ":"JWT"}"#);
        let payload = URL_SAFE_NO_PAD.encode(format!(
            r#"{{"https://api.openai.com/auth":{{"chatgpt_account_id":"{account_id}","chatgpt_plan_type":"plus"}},"https://api.openai.com/profile":{{"email":"demo@example.com"}}}}"#
        ));
        format!("{header}.{payload}.signature")
    }

    #[test]
    fn validates_minimum_import_auth_json_shape() {
        let payload = serde_json::json!({
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": null,
            "tokens": {
                "id_token": fake_jwt("workspace-1"),
                "access_token": fake_jwt("workspace-1"),
                "refresh_token": "rt_123",
                "account_id": "workspace-1"
            },
            "last_refresh": "2026-04-11T12:25:13.160706Z"
        });
        let auth_json = extract_import_auth_json(payload).expect("auth json should parse");
        validate_imported_auth_json(&auth_json).expect("auth json should validate");
    }

    #[test]
    fn rejects_import_without_tokens() {
        let payload = serde_json::json!({
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": null
        });
        let auth_json = extract_import_auth_json(payload).expect("auth json should parse");
        let error = validate_imported_auth_json(&auth_json).expect_err("validation should fail");
        assert!(error.to_string().contains("missing tokens"));
    }
}
