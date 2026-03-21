use std::{
    collections::{HashMap, VecDeque},
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};

use chrono::Utc;
use serde::{Deserialize, Serialize};

pub const ENABLE_RUNTIME_LOGGING: bool = true;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeSettings {
    pub logging_enabled: bool,
    pub max_lines_per_file: usize,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeLogSource {
    FlutterMobile,
    FlutterDesktop,
    DesktopBackend,
    ServerBackend,
}

impl RuntimeLogSource {
    pub fn file_name(self) -> &'static str {
        match self {
            Self::FlutterMobile => "flutter-mobile.log",
            Self::FlutterDesktop => "flutter-desktop.log",
            Self::DesktopBackend => "desktop-backend.log",
            Self::ServerBackend => "server-backend.log",
        }
    }
}

pub struct RuntimeLogStore {
    run_dir: PathBuf,
    max_lines_per_file: usize,
    buffers: Mutex<HashMap<RuntimeLogSource, VecDeque<String>>>,
}

impl RuntimeLogStore {
    pub fn new(
        logs_root_dir: impl AsRef<Path>,
        max_run_directories: usize,
        max_lines_per_file: usize,
    ) -> anyhow::Result<Self> {
        let logs_root_dir = logs_root_dir.as_ref().to_path_buf();
        fs::create_dir_all(&logs_root_dir)?;

        let run_dir = logs_root_dir.join(Utc::now().format("%Y%m%d-%H%M%S").to_string());
        fs::create_dir_all(&run_dir)?;
        prune_old_run_directories(&logs_root_dir, max_run_directories.max(1))?;

        Ok(Self {
            run_dir,
            max_lines_per_file: max_lines_per_file.max(1),
            buffers: Mutex::new(HashMap::new()),
        })
    }

    pub fn append_line(&self, source: RuntimeLogSource, line: String) -> anyhow::Result<()> {
        let lines = {
            let mut buffers = self
                .buffers
                .lock()
                .map_err(|_| anyhow::anyhow!("runtime log store mutex poisoned"))?;
            let buffer = buffers.entry(source).or_insert_with(VecDeque::new);
            buffer.push_back(line);
            while buffer.len() > self.max_lines_per_file {
                buffer.pop_front();
            }
            buffer.iter().cloned().collect::<Vec<_>>()
        };

        let output = if lines.is_empty() {
            String::new()
        } else {
            let mut output = lines.join("\n");
            output.push('\n');
            output
        };
        fs::write(self.run_dir.join(source.file_name()), output)?;
        Ok(())
    }

    pub fn run_dir(&self) -> &Path {
        &self.run_dir
    }
}

fn prune_old_run_directories(
    logs_root_dir: &Path,
    max_run_directories: usize,
) -> anyhow::Result<()> {
    let mut directories = fs::read_dir(logs_root_dir)?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false))
        .collect::<Vec<_>>();

    directories.sort_by_key(|entry| entry.file_name());

    let delete_count = directories.len().saturating_sub(max_run_directories);
    for entry in directories.into_iter().take(delete_count) {
        fs::remove_dir_all(entry.path())?;
    }

    Ok(())
}
