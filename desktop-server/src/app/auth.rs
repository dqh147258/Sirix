use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::Context;
use serde::{Deserialize, Serialize};
use tokio::{fs, sync::RwLock};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthSession {
    pub user_id: String,
    pub username: String,
    pub access_token: String,
    pub refresh_token: String,
}

#[derive(Clone)]
pub struct AuthSessionStore {
    base_url: Arc<String>,
    client: reqwest::Client,
    session: Arc<RwLock<Option<AuthSession>>>,
    session_file_path: Arc<PathBuf>,
}

#[derive(Debug, Serialize)]
struct LoginRequest<'a> {
    username: &'a str,
    password: &'a str,
    client_type: &'a str,
}

#[derive(Debug, Serialize)]
struct RegisterRequest<'a> {
    username: &'a str,
    password: &'a str,
}

#[derive(Debug, Serialize)]
struct RefreshRequest<'a> {
    refresh_token: &'a str,
}

enum RefreshSessionError {
    Invalid,
    Transient(anyhow::Error),
}

impl AuthSessionStore {
    pub fn new(base_url: String, session_file_path: PathBuf) -> Self {
        Self {
            base_url: Arc::new(base_url.trim_end_matches('/').to_string()),
            client: reqwest::Client::new(),
            session: Arc::new(RwLock::new(None)),
            session_file_path: Arc::new(session_file_path),
        }
    }

    pub async fn restore(&self) -> anyhow::Result<Option<AuthSession>> {
        let Some(stored) = self.read_session_file().await? else {
            self.set_cached_session(None).await;
            return Ok(None);
        };

        match self.refresh_with_token(&stored.refresh_token).await {
            Ok(refreshed) => {
                self.persist_session(Some(&refreshed)).await?;
                Ok(Some(refreshed))
            }
            Err(RefreshSessionError::Invalid) => {
                self.clear().await?;
                Ok(None)
            }
            Err(RefreshSessionError::Transient(error)) => Err(error),
        }
    }

    pub async fn current_session(&self) -> Option<AuthSession> {
        self.session.read().await.clone()
    }

    pub async fn login(&self, username: &str, password: &str) -> anyhow::Result<AuthSession> {
        let response = self
            .client
            .post(self.endpoint("/api/v1/auth/login"))
            .json(&LoginRequest {
                username,
                password,
                client_type: "desktop",
            })
            .send()
            .await
            .context("failed to call backend login")?;

        let session = decode_auth_session_response(response).await?;
        self.persist_session(Some(&session)).await?;
        Ok(session)
    }

    pub async fn register(&self, username: &str, password: &str) -> anyhow::Result<AuthSession> {
        let response = self
            .client
            .post(self.endpoint("/api/v1/auth/register"))
            .json(&RegisterRequest { username, password })
            .send()
            .await
            .context("failed to call backend register")?;

        let session = decode_auth_session_response(response).await?;
        self.persist_session(Some(&session)).await?;
        Ok(session)
    }

    pub async fn refresh_current_session(&self) -> anyhow::Result<Option<AuthSession>> {
        let cached = self.current_session().await;
        let Some(cached) = cached else {
            return self.restore().await;
        };

        match self.refresh_with_token(&cached.refresh_token).await {
            Ok(refreshed) => {
                self.persist_session(Some(&refreshed)).await?;
                Ok(Some(refreshed))
            }
            Err(RefreshSessionError::Invalid) => {
                self.clear().await?;
                Ok(None)
            }
            Err(RefreshSessionError::Transient(error)) => Err(error),
        }
    }

    pub async fn clear(&self) -> anyhow::Result<()> {
        self.set_cached_session(None).await;

        match fs::remove_file(self.session_file_path.as_path()).await {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error).context("failed to remove auth session file"),
        }
    }

    async fn refresh_with_token(
        &self,
        refresh_token: &str,
    ) -> Result<AuthSession, RefreshSessionError> {
        let response = self
            .client
            .post(self.endpoint("/api/v1/auth/refresh"))
            .json(&RefreshRequest { refresh_token })
            .send()
            .await
            .context("failed to call backend refresh")
            .map_err(RefreshSessionError::Transient)?;

        let status = response.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            let _ = response.text().await;
            return Err(RefreshSessionError::Invalid);
        }

        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(RefreshSessionError::Transient(anyhow::anyhow!(
                "backend refresh failed status={} body={}",
                status,
                body
            )));
        }

        response
            .json::<AuthSession>()
            .await
            .context("failed to decode backend refresh response")
            .map_err(RefreshSessionError::Transient)
    }

    async fn persist_session(&self, session: Option<&AuthSession>) -> anyhow::Result<()> {
        self.set_cached_session(session.cloned()).await;

        let Some(session) = session else {
            return Ok(());
        };

        ensure_parent_dir(self.session_file_path.as_path()).await?;
        let payload =
            serde_json::to_vec_pretty(session).context("failed to serialize auth session")?;
        fs::write(self.session_file_path.as_path(), payload)
            .await
            .context("failed to persist auth session")?;
        Ok(())
    }

    async fn read_session_file(&self) -> anyhow::Result<Option<AuthSession>> {
        let path = self.session_file_path.as_path();
        let content = match fs::read(path).await {
            Ok(content) => content,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).context("failed to read auth session file"),
        };

        let session = serde_json::from_slice::<AuthSession>(&content)
            .context("failed to decode auth session file")?;
        Ok(Some(session))
    }

    async fn set_cached_session(&self, session: Option<AuthSession>) {
        *self.session.write().await = session;
    }

    fn endpoint(&self, path: &str) -> String {
        format!("{}{}", self.base_url.as_str(), path)
    }
}

async fn ensure_parent_dir(path: &Path) -> anyhow::Result<()> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };

    fs::create_dir_all(parent)
        .await
        .context("failed to create auth session directory")?;
    Ok(())
}

async fn decode_auth_session_response(response: reqwest::Response) -> anyhow::Result<AuthSession> {
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!(
            "backend auth request failed status={} body={}",
            status,
            body
        );
    }

    response
        .json::<AuthSession>()
        .await
        .context("failed to decode backend auth response")
}
