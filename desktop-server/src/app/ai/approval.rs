use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::Context;
use tokio::sync::RwLock;
use uuid::Uuid;

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
    // ai_session_id -> capability_key -> decision
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
        capability_key: &str,
    ) -> Option<ApprovalRecord> {
        let mut guard = self.records.write().await;
        let capability_map = guard.get_mut(&ai_session_id)?;
        let record = capability_map.get(capability_key).copied()?;
        match record.scope {
            ApprovalScope::Once => {
                capability_map.remove(capability_key);
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
        capability_key: String,
        record: ApprovalRecord,
    ) {
        let snapshot = {
            let mut guard = self.records.write().await;
            let capability_map = guard.entry(ai_session_id).or_default();
            capability_map.insert(capability_key, record);
            capability_map.clone()
        };
        if let Err(error) = persist_session_records(&self.storage_dir, ai_session_id, Some(&snapshot)) {
            tracing::warn!(
                ai_session_id = %ai_session_id,
                error = %error,
                "failed to persist approval record"
            );
        }
    }

    pub async fn mark_pending(&self, ai_session_id: Uuid, capability_key: &str) -> bool {
        let mut guard = self.pending_requests.write().await;
        guard.insert((ai_session_id, capability_key.to_string()))
    }

    pub async fn clear_pending(&self, ai_session_id: Uuid, capability_key: &str) {
        self.pending_requests
            .write()
            .await
            .remove(&(ai_session_id, capability_key.to_string()));
    }
}

fn load_records(storage_dir: &Path) -> anyhow::Result<HashMap<Uuid, HashMap<String, ApprovalRecord>>> {
    let mut records = HashMap::new();
    for entry in
        fs::read_dir(storage_dir).with_context(|| format!("failed to read {}", storage_dir.display()))?
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
