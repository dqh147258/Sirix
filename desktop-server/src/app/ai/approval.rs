use std::{
    collections::{HashMap, HashSet},
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
    Deny,
}

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ApprovalRecord {
    pub decision: ApprovalDecision,
    pub scope: ApprovalScope,
}

#[derive(Default)]
pub struct AiApprovalRegistry {
    storage_dir: PathBuf,
    // ai_session_id -> (agent_id + capability_key) -> decision
    records: Arc<RwLock<HashMap<Uuid, HashMap<String, ApprovalRecord>>>>,
    pending_requests: Arc<RwLock<HashSet<(Uuid, String)>>>,
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
            pending_requests: Arc::new(RwLock::new(HashSet::new())),
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
            ApprovalScope::Session | ApprovalScope::Deny => Some(record),
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
    ) -> bool {
        let mut guard = self.pending_requests.write().await;
        guard.insert((ai_session_id, approval_record_key(agent_id, capability_key)))
    }

    pub async fn clear_pending(&self, ai_session_id: Uuid, agent_id: &str, capability_key: &str) {
        self.pending_requests
            .write()
            .await
            .remove(&(ai_session_id, approval_record_key(agent_id, capability_key)));
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
                .mark_pending(session_id, "agent-a", "builtin.apply_patch")
                .await
        );
        assert!(
            registry
                .mark_pending(session_id, "agent-b", "builtin.apply_patch")
                .await
        );
        assert!(
            !registry
                .mark_pending(session_id, "agent-a", "builtin.apply_patch")
                .await
        );

        registry
            .clear_pending(session_id, "agent-a", "builtin.apply_patch")
            .await;
        assert!(
            registry
                .mark_pending(session_id, "agent-a", "builtin.apply_patch")
                .await
        );
        assert!(
            !registry
                .mark_pending(session_id, "agent-b", "builtin.apply_patch")
                .await
        );

        fs::remove_dir_all(storage_dir).expect("remove temp approval dir");
    }
}
