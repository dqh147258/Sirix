use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::Context;
use tokio::sync::RwLock;
use uuid::Uuid;

const APPROVAL_KEY_SEPARATOR: char = '\u{1f}';

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalDecision {
    Allow,
    Deny,
}

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalScope {
    Once,
    Session,
    Workspace,
    Global,
}

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ApprovalRecord {
    pub decision: ApprovalDecision,
    pub scope: ApprovalScope,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ShellApprovalRequestRecord {
    pub request_id: String,
    pub command: Vec<String>,
    pub supported_scopes: Vec<String>,
    pub prefix_candidates: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ShellApprovalResolutionRecord {
    pub decision: ApprovalDecision,
    pub scope: ApprovalScope,
    pub prefix: Option<String>,
}

#[derive(Default)]
pub struct AiApprovalRegistry {
    storage_dir: PathBuf,
    // ai_session_id -> (agent_id + capability_key) -> decision
    records: Arc<RwLock<HashMap<Uuid, HashMap<String, ApprovalRecord>>>>,
    // ai_session_id + (agent_id + capability_key) -> current request_id
    pending_requests: Arc<RwLock<HashMap<(Uuid, String), String>>>,
}

#[derive(Default)]
pub struct ShellApprovalRegistry {
    pending_requests: Arc<RwLock<HashMap<(Uuid, String), ShellApprovalRequestRecord>>>,
    resolved_requests: Arc<RwLock<HashMap<(Uuid, String), ShellApprovalResolutionRecord>>>,
}

impl AiApprovalRegistry {
    pub fn new(storage_root: impl AsRef<Path>) -> anyhow::Result<Self> {
        let storage_dir = storage_root.as_ref().to_path_buf();
        fs::create_dir_all(&storage_dir)
            .with_context(|| format!("failed to create {}", storage_dir.display()))?;
        let records = load_records(&storage_dir)?;
        Ok(Self {
            storage_dir,
            records: Arc::new(RwLock::new(records)),
            pending_requests: Arc::new(RwLock::new(HashMap::new())),
        })
    }

    pub async fn resolve_for_check(
        &self,
        ai_session_id: Uuid,
        agent_id: &str,
        capability_key: &str,
    ) -> Option<ApprovalRecord> {
        let key = approval_record_key(agent_id, capability_key);
        let mut guard = self.records.write().await;
        let capability_map = guard.get_mut(&ai_session_id)?;
        let record = capability_map.get(&key).copied()?;
        match record.scope {
            ApprovalScope::Once => {
                capability_map.remove(&key);
                let should_delete = capability_map.is_empty();
                let snapshot = if should_delete {
                    None
                } else {
                    Some(capability_map.clone())
                };
                drop(guard);
                if let Err(error) =
                    persist_session_records(&self.storage_dir, ai_session_id, snapshot.as_ref())
                {
                    tracing::warn!(
                        ai_session_id = %ai_session_id,
                        agent_id,
                        capability_key,
                        error = %error,
                        "failed to persist once approval removal"
                    );
                }
                Some(record)
            }
            ApprovalScope::Session | ApprovalScope::Workspace | ApprovalScope::Global => {
                Some(record)
            }
        }
    }

    pub async fn set(
        &self,
        ai_session_id: Uuid,
        agent_id: &str,
        capability_key: &str,
        record: ApprovalRecord,
    ) {
        let key = approval_record_key(agent_id, capability_key);
        let snapshot = {
            let mut guard = self.records.write().await;
            let capability_map = guard.entry(ai_session_id).or_default();
            capability_map.insert(key, record);
            capability_map.clone()
        };
        if let Err(error) =
            persist_session_records(&self.storage_dir, ai_session_id, Some(&snapshot))
        {
            tracing::warn!(
                ai_session_id = %ai_session_id,
                agent_id,
                capability_key,
                error = %error,
                "failed to persist approval record"
            );
        }
    }

    pub async fn mark_pending(
        &self,
        ai_session_id: Uuid,
        agent_id: &str,
        capability_key: &str,
        request_id: &str,
    ) -> bool {
        let request_id = request_id.trim();
        if request_id.is_empty() {
            return false;
        }
        let mut guard = self.pending_requests.write().await;
        let key = (ai_session_id, approval_record_key(agent_id, capability_key));
        if guard.contains_key(&key) {
            return false;
        }
        guard.insert(key, request_id.to_string());
        true
    }

    pub async fn clear_pending(&self, ai_session_id: Uuid, agent_id: &str, capability_key: &str) {
        self.pending_requests
            .write()
            .await
            .remove(&(ai_session_id, approval_record_key(agent_id, capability_key)));
    }

    pub async fn take_pending(
        &self,
        ai_session_id: Uuid,
        agent_id: &str,
        capability_key: &str,
        request_id: Option<&str>,
    ) -> Option<String> {
        let key = (ai_session_id, approval_record_key(agent_id, capability_key));
        let mut guard = self.pending_requests.write().await;
        let existing_request_id = guard.get(&key)?.clone();
        if let Some(request_id) = request_id.map(str::trim).filter(|value| !value.is_empty()) {
            if existing_request_id != request_id {
                return None;
            }
        }
        guard.remove(&key);
        Some(existing_request_id)
    }

    pub async fn restore_pending(
        &self,
        ai_session_id: Uuid,
        agent_id: &str,
        capability_key: &str,
        request_id: &str,
    ) {
        let request_id = request_id.trim();
        if request_id.is_empty() {
            return;
        }
        self.pending_requests.write().await.insert(
            (ai_session_id, approval_record_key(agent_id, capability_key)),
            request_id.to_string(),
        );
    }
}

impl ShellApprovalRegistry {
    pub async fn upsert_pending(&self, ai_session_id: Uuid, request: ShellApprovalRequestRecord) {
        let key = (ai_session_id, request.request_id.clone());
        self.resolved_requests.write().await.remove(&key);
        self.pending_requests.write().await.insert(key, request);
    }

    pub async fn pending_request(
        &self,
        ai_session_id: Uuid,
        request_id: &str,
    ) -> Option<ShellApprovalRequestRecord> {
        self.pending_requests
            .read()
            .await
            .get(&(ai_session_id, request_id.trim().to_string()))
            .cloned()
    }

    pub async fn resolve(
        &self,
        ai_session_id: Uuid,
        request_id: &str,
        resolution: ShellApprovalResolutionRecord,
    ) {
        let key = (ai_session_id, request_id.trim().to_string());
        self.pending_requests.write().await.remove(&key);
        self.resolved_requests.write().await.insert(key, resolution);
    }

    pub async fn resolution(
        &self,
        ai_session_id: Uuid,
        request_id: &str,
    ) -> Option<ShellApprovalResolutionRecord> {
        self.resolved_requests
            .read()
            .await
            .get(&(ai_session_id, request_id.trim().to_string()))
            .cloned()
    }
}

fn approval_record_key(agent_id: &str, capability_key: &str) -> String {
    // Persist approvals per-session and per-agent so one sub-agent's cached
    // answer cannot silently satisfy another sub-agent asking for the same
    // capability later in the thread.
    format!(
        "{}{APPROVAL_KEY_SEPARATOR}{}",
        agent_id.trim(),
        capability_key.trim()
    )
}

fn load_records(
    storage_dir: &Path,
) -> anyhow::Result<HashMap<Uuid, HashMap<String, ApprovalRecord>>> {
    let mut records = HashMap::new();
    for entry in fs::read_dir(storage_dir)
        .with_context(|| format!("failed to read {}", storage_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|value| value.to_str()) else {
            continue;
        };
        let session_id = match Uuid::parse_str(stem) {
            Ok(value) => value,
            Err(_) => continue,
        };
        let raw = fs::read_to_string(&path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let parsed = serde_json::from_str::<HashMap<String, ApprovalRecord>>(&raw)
            .with_context(|| format!("failed to parse {}", path.display()))?;
        if !parsed.is_empty() {
            records.insert(session_id, parsed);
        }
    }
    Ok(records)
}

fn persist_session_records(
    storage_dir: &Path,
    ai_session_id: Uuid,
    records: Option<&HashMap<String, ApprovalRecord>>,
) -> anyhow::Result<()> {
    let path = storage_dir.join(format!("{ai_session_id}.json"));
    match records {
        Some(records) if !records.is_empty() => {
            let serialized =
                serde_json::to_string_pretty(records).context("failed to serialize approvals")?;
            fs::write(&path, serialized)
                .with_context(|| format!("failed to write {}", path.display()))?;
        }
        _ => {
            if path.exists() {
                fs::remove_file(&path)
                    .with_context(|| format!("failed to remove {}", path.display()))?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{env, fs};

    fn temp_storage_dir(test_name: &str) -> PathBuf {
        let path = env::temp_dir().join(format!("sirix-approval-{test_name}-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).expect("create temp approval dir");
        path
    }

    #[tokio::test]
    async fn approvals_are_isolated_per_agent() {
        let storage_dir = temp_storage_dir("isolated-per-agent");
        let registry = AiApprovalRegistry::new(&storage_dir).expect("registry");
        let session_id = Uuid::new_v4();

        registry
            .set(
                session_id,
                "agent-a",
                "builtin.apply_patch",
                ApprovalRecord {
                    decision: ApprovalDecision::Allow,
                    scope: ApprovalScope::Session,
                },
            )
            .await;
        registry
            .set(
                session_id,
                "agent-b",
                "builtin.apply_patch",
                ApprovalRecord {
                    decision: ApprovalDecision::Deny,
                    scope: ApprovalScope::Session,
                },
            )
            .await;

        assert_eq!(
            registry
                .resolve_for_check(session_id, "agent-a", "builtin.apply_patch")
                .await,
            Some(ApprovalRecord {
                decision: ApprovalDecision::Allow,
                scope: ApprovalScope::Session,
            })
        );
        assert_eq!(
            registry
                .resolve_for_check(session_id, "agent-b", "builtin.apply_patch")
                .await,
            Some(ApprovalRecord {
                decision: ApprovalDecision::Deny,
                scope: ApprovalScope::Session,
            })
        );

        fs::remove_dir_all(storage_dir).expect("remove temp approval dir");
    }

    #[tokio::test]
    async fn pending_requests_are_isolated_per_agent() {
        let storage_dir = temp_storage_dir("pending-per-agent");
        let registry = AiApprovalRegistry::new(&storage_dir).expect("registry");
        let session_id = Uuid::new_v4();

        assert!(
            registry
                .mark_pending(session_id, "agent-a", "builtin.apply_patch", "req-a")
                .await
        );
        assert!(
            registry
                .mark_pending(session_id, "agent-b", "builtin.apply_patch", "req-b")
                .await
        );
        assert!(
            !registry
                .mark_pending(session_id, "agent-a", "builtin.apply_patch", "req-c")
                .await
        );

        registry
            .clear_pending(session_id, "agent-a", "builtin.apply_patch")
            .await;
        assert!(
            registry
                .mark_pending(session_id, "agent-a", "builtin.apply_patch", "req-d")
                .await
        );
        assert!(
            !registry
                .mark_pending(session_id, "agent-b", "builtin.apply_patch", "req-e")
                .await
        );

        fs::remove_dir_all(storage_dir).expect("remove temp approval dir");
    }

    #[tokio::test]
    async fn take_pending_requires_matching_request_id_when_provided() {
        let storage_dir = temp_storage_dir("pending-request-id");
        let registry = AiApprovalRegistry::new(&storage_dir).expect("registry");
        let session_id = Uuid::new_v4();

        assert!(
            registry
                .mark_pending(session_id, "agent-a", "builtin.apply_patch", "req-1")
                .await
        );
        assert!(registry
            .take_pending(
                session_id,
                "agent-a",
                "builtin.apply_patch",
                Some("req-mismatch"),
            )
            .await
            .is_none());
        assert_eq!(
            registry
                .take_pending(session_id, "agent-a", "builtin.apply_patch", Some("req-1"))
                .await,
            Some("req-1".to_string())
        );
        assert!(registry
            .take_pending(session_id, "agent-a", "builtin.apply_patch", Some("req-1"))
            .await
            .is_none());

        fs::remove_dir_all(storage_dir).expect("remove temp approval dir");
    }

    #[tokio::test]
    async fn shell_registry_replaces_stale_resolution_on_new_request() {
        let registry = ShellApprovalRegistry::default();
        let session_id = Uuid::new_v4();
        let request_id = "req-1";

        registry
            .resolve(
                session_id,
                request_id,
                ShellApprovalResolutionRecord {
                    decision: ApprovalDecision::Allow,
                    scope: ApprovalScope::Once,
                    prefix: None,
                },
            )
            .await;

        registry
            .upsert_pending(
                session_id,
                ShellApprovalRequestRecord {
                    request_id: request_id.to_string(),
                    command: vec!["bash".to_string(), "-lc".to_string(), "ls".to_string()],
                    supported_scopes: vec!["once".to_string(), "session".to_string()],
                    prefix_candidates: vec!["ls".to_string()],
                },
            )
            .await;

        assert!(registry.resolution(session_id, request_id).await.is_none());
        assert!(registry
            .pending_request(session_id, request_id)
            .await
            .is_some());
    }
}
