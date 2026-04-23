use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::Context;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Best-effort persisted metadata for server-owned/shared terminal runtimes.
///
/// This is intentionally narrower than the in-memory canonical terminal state:
/// it records enough information for future restart reconciliation and operator
/// inspection, without pretending that a JSON file is itself the terminal
/// truth. The authoritative screen/history state still lives in memory inside
/// Desktop Server.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TerminalRuntimeRecord {
    pub terminal_id: Uuid,
    pub source: String,
    pub state: String,
    pub title: String,
    pub shell: String,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    pub authority_source: String,
    pub geometry_generation: u64,
    pub created_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
    pub tmux_session_name: Option<String>,
    #[serde(default = "default_recovery_strategy")]
    pub recovery_strategy: String,
}

fn default_recovery_strategy() -> String {
    "unknown".to_string()
}

pub fn runtime_registry_root(sirix_home: &Path) -> PathBuf {
    sirix_home.join("runtime").join("terminals")
}

pub fn persist_runtime_record(
    sirix_home: &Path,
    record: &TerminalRuntimeRecord,
) -> anyhow::Result<PathBuf> {
    let root = runtime_registry_root(sirix_home);
    fs::create_dir_all(&root).with_context(|| {
        format!(
            "failed to create terminal runtime registry {}",
            root.display()
        )
    })?;
    let path = root.join(format!("{}.json", record.terminal_id));
    let content = serde_json::to_vec_pretty(record)
        .context("failed to encode terminal runtime registry record")?;
    fs::write(&path, content).with_context(|| {
        format!(
            "failed to write terminal runtime registry {}",
            path.display()
        )
    })?;
    Ok(path)
}

pub fn remove_runtime_record(sirix_home: &Path, terminal_id: Uuid) -> anyhow::Result<()> {
    let path = runtime_registry_root(sirix_home).join(format!("{terminal_id}.json"));
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| {
            format!(
                "failed to remove terminal runtime registry {}",
                path.display()
            )
        }),
    }
}

pub fn load_runtime_records(sirix_home: &Path) -> anyhow::Result<Vec<TerminalRuntimeRecord>> {
    let root = runtime_registry_root(sirix_home);
    if !root.exists() {
        return Ok(Vec::new());
    }

    let mut records = Vec::new();
    for entry in fs::read_dir(&root).with_context(|| {
        format!(
            "failed to read terminal runtime registry {}",
            root.display()
        )
    })? {
        let entry = entry.with_context(|| {
            format!(
                "failed to inspect terminal runtime registry {}",
                root.display()
            )
        })?;
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let content = fs::read_to_string(&path).with_context(|| {
            format!(
                "failed to read terminal runtime registry record {}",
                path.display()
            )
        })?;
        let record =
            serde_json::from_str::<TerminalRuntimeRecord>(&content).with_context(|| {
                format!(
                    "failed to decode terminal runtime registry record {}",
                    path.display()
                )
            })?;
        records.push(record);
    }
    records.sort_by_key(|record| record.created_at);
    Ok(records)
}

pub fn load_runtime_record(
    sirix_home: &Path,
    terminal_id: Uuid,
) -> anyhow::Result<Option<TerminalRuntimeRecord>> {
    let path = runtime_registry_root(sirix_home).join(format!("{terminal_id}.json"));
    if !path.exists() {
        return Ok(None);
    }
    let content = fs::read_to_string(&path).with_context(|| {
        format!(
            "failed to read terminal runtime registry record {}",
            path.display()
        )
    })?;
    let record = serde_json::from_str::<TerminalRuntimeRecord>(&content).with_context(|| {
        format!(
            "failed to decode terminal runtime registry record {}",
            path.display()
        )
    })?;
    Ok(Some(record))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persist_and_remove_runtime_record_round_trips() {
        let root =
            std::env::temp_dir().join(format!("sirix-terminal-runtime-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp sirix home should be created");

        let record = TerminalRuntimeRecord {
            terminal_id: Uuid::new_v4(),
            source: "local_pty".to_string(),
            state: "active".to_string(),
            title: "Terminal".to_string(),
            shell: "bash".to_string(),
            cwd: "/tmp".to_string(),
            cols: 120,
            rows: 32,
            authority_source: "server_default".to_string(),
            geometry_generation: 4,
            created_at: Utc::now(),
            closed_at: None,
            tmux_session_name: Some("sirix-test".to_string()),
            recovery_strategy: "tmux_takeover".to_string(),
        };

        let path = persist_runtime_record(&root, &record).expect("runtime record should persist");
        let decoded =
            fs::read_to_string(&path).expect("persisted runtime record should be readable");
        let reloaded: TerminalRuntimeRecord =
            serde_json::from_str(&decoded).expect("persisted runtime record should decode");
        assert_eq!(reloaded.terminal_id, record.terminal_id);
        assert_eq!(reloaded.source, record.source);
        assert_eq!(reloaded.tmux_session_name, record.tmux_session_name);
        assert_eq!(reloaded.recovery_strategy, record.recovery_strategy);

        remove_runtime_record(&root, record.terminal_id).expect("runtime record should be removed");
        assert!(
            !path.exists(),
            "registry file should be removed after cleanup"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn load_runtime_records_returns_sorted_records() {
        let root =
            std::env::temp_dir().join(format!("sirix-terminal-runtime-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp sirix home should be created");

        let mut records = vec![
            TerminalRuntimeRecord {
                terminal_id: Uuid::new_v4(),
                source: "local_pty".to_string(),
                state: "active".to_string(),
                title: "later".to_string(),
                shell: "bash".to_string(),
                cwd: "/tmp".to_string(),
                cols: 100,
                rows: 30,
                authority_source: "desktop_app".to_string(),
                geometry_generation: 2,
                created_at: Utc::now() + chrono::TimeDelta::seconds(1),
                closed_at: None,
                tmux_session_name: None,
                recovery_strategy: "process_bound_ephemeral".to_string(),
            },
            TerminalRuntimeRecord {
                terminal_id: Uuid::new_v4(),
                source: "local_pty".to_string(),
                state: "active".to_string(),
                title: "earlier".to_string(),
                shell: "zsh".to_string(),
                cwd: "/workspace".to_string(),
                cols: 120,
                rows: 32,
                authority_source: "system_terminal".to_string(),
                geometry_generation: 1,
                created_at: Utc::now(),
                closed_at: None,
                tmux_session_name: Some("sirix-a".to_string()),
                recovery_strategy: "tmux_takeover".to_string(),
            },
        ];
        for record in &records {
            persist_runtime_record(&root, record).expect("runtime record should persist");
        }

        let loaded = load_runtime_records(&root).expect("runtime records should load");
        records.sort_by_key(|record| record.created_at);
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].terminal_id, records[0].terminal_id);
        assert_eq!(loaded[1].terminal_id, records[1].terminal_id);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn load_runtime_record_returns_single_record() {
        let root =
            std::env::temp_dir().join(format!("sirix-terminal-runtime-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp sirix home should be created");

        let record = TerminalRuntimeRecord {
            terminal_id: Uuid::new_v4(),
            source: "local_pty".to_string(),
            state: "active".to_string(),
            title: "single".to_string(),
            shell: "bash".to_string(),
            cwd: "/tmp".to_string(),
            cols: 80,
            rows: 24,
            authority_source: "desktop_app".to_string(),
            geometry_generation: 5,
            created_at: Utc::now(),
            closed_at: None,
            tmux_session_name: None,
            recovery_strategy: "process_bound_ephemeral".to_string(),
        };
        persist_runtime_record(&root, &record).expect("runtime record should persist");

        let loaded = load_runtime_record(&root, record.terminal_id)
            .expect("runtime record should load")
            .expect("runtime record should exist");
        assert_eq!(loaded.terminal_id, record.terminal_id);
        assert_eq!(loaded.title, "single");

        let _ = fs::remove_dir_all(&root);
    }
}
