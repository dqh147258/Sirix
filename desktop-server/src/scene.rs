use std::{env, path::PathBuf};

use anyhow::Context;

pub const SIRIX_SCENE_ENV: &str = "SIRIX_SCENE";
pub const SIRIX_WORKSPACE_CONFIG_DIRNAME_ENV: &str = "SIRIX_WORKSPACE_CONFIG_DIRNAME";
pub const SIRIX_DESKTOP_SERVER_CONFIG_PATH_ENV: &str = "SIRIX_DESKTOP_SERVER_CONFIG_PATH";

pub const RELEASE_GLOBAL_DIR_NAME: &str = ".sirix";
pub const DEBUG_GLOBAL_DIR_NAME: &str = ".sirix-debug";
pub const RELEASE_DEVICE_ID: &str = "00000000-0000-0000-0000-000000000001";
pub const DEBUG_DEVICE_ID: &str = "00000000-0000-0000-0000-000000000101";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SirixScene {
    Debug,
    Release,
}

impl SirixScene {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Debug => "debug",
            Self::Release => "release",
        }
    }

    pub fn runtime_profile(self) -> &'static str {
        self.as_str()
    }

    pub fn global_dir_name(self) -> &'static str {
        match self {
            Self::Debug => DEBUG_GLOBAL_DIR_NAME,
            Self::Release => RELEASE_GLOBAL_DIR_NAME,
        }
    }

    pub fn workspace_dir_name(self) -> &'static str {
        self.global_dir_name()
    }

    pub fn default_backend_port(self) -> u16 {
        match self {
            Self::Debug => 46110,
            Self::Release => 46120,
        }
    }

    pub fn default_local_ws_port_start(self) -> u16 {
        match self {
            Self::Debug => 46111,
            Self::Release => 46121,
        }
    }

    pub fn default_local_ws_port_end(self) -> u16 {
        match self {
            Self::Debug => 46119,
            Self::Release => 46129,
        }
    }

    pub fn default_device_id(self) -> &'static str {
        match self {
            Self::Debug => DEBUG_DEVICE_ID,
            Self::Release => RELEASE_DEVICE_ID,
        }
    }
}

pub fn resolve_scene() -> anyhow::Result<SirixScene> {
    if let Some(explicit) = env::var(SIRIX_SCENE_ENV)
        .ok()
        .and_then(|value| parse_scene(&value))
    {
        validate_explicit_home_against_scene(explicit)?;
        validate_workspace_dir_name_against_scene(explicit)?;
        return Ok(explicit);
    }

    if let Ok(explicit_home) = env::var("SIRIX_HOME") {
        let trimmed = explicit_home.trim();
        if !trimmed.is_empty() {
            let explicit_path = PathBuf::from(trimmed);
            if path_matches_canonical_scene(&explicit_path, SirixScene::Release)? {
                return Ok(SirixScene::Release);
            }
            if path_matches_canonical_scene(&explicit_path, SirixScene::Debug)? {
                return Ok(SirixScene::Debug);
            }
        }
    }

    if let Ok(current_exe) = env::current_exe() {
        if path_matches_scene_bin_home(&current_exe, SirixScene::Release)? {
            return Ok(SirixScene::Release);
        }
        if path_matches_scene_bin_home(&current_exe, SirixScene::Debug)? {
            return Ok(SirixScene::Debug);
        }
    }

    Ok(SirixScene::Debug)
}

pub fn resolve_sirix_home() -> anyhow::Result<PathBuf> {
    let scene = resolve_scene()?;
    if let Ok(explicit) = env::var("SIRIX_HOME") {
        if !explicit.trim().is_empty() {
            return Ok(PathBuf::from(explicit));
        }
    }
    canonical_home_for_scene(scene)
}

pub fn resolve_workspace_config_dir_name() -> anyhow::Result<String> {
    let scene = resolve_scene()?;
    if let Ok(explicit) = env::var(SIRIX_WORKSPACE_CONFIG_DIRNAME_ENV) {
        let trimmed = explicit.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }
    Ok(scene.workspace_dir_name().to_string())
}

pub fn canonical_home_for_scene(scene: SirixScene) -> anyhow::Result<PathBuf> {
    let home = user_home_dir()?;
    Ok(home.join(scene.global_dir_name()))
}

pub fn parse_scene(raw: &str) -> Option<SirixScene> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "debug" => Some(SirixScene::Debug),
        "release" => Some(SirixScene::Release),
        _ => None,
    }
}

fn validate_explicit_home_against_scene(scene: SirixScene) -> anyhow::Result<()> {
    let Ok(explicit) = env::var("SIRIX_HOME") else {
        return Ok(());
    };
    let trimmed = explicit.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    let explicit_path = PathBuf::from(trimmed);
    let opposite = match scene {
        SirixScene::Debug => SirixScene::Release,
        SirixScene::Release => SirixScene::Debug,
    };
    if path_matches_canonical_scene(&explicit_path, opposite)? {
        anyhow::bail!(
            "SIRIX_SCENE={} conflicts with SIRIX_HOME={}, which points at the {} canonical Sirix home",
            scene.as_str(),
            explicit_path.display(),
            opposite.as_str()
        );
    }
    Ok(())
}

fn validate_workspace_dir_name_against_scene(scene: SirixScene) -> anyhow::Result<()> {
    let Ok(explicit) = env::var(SIRIX_WORKSPACE_CONFIG_DIRNAME_ENV) else {
        return Ok(());
    };
    let trimmed = explicit.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    let opposite = match scene {
        SirixScene::Debug => SirixScene::Release,
        SirixScene::Release => SirixScene::Debug,
    };
    if trimmed == opposite.workspace_dir_name() {
        anyhow::bail!(
            "{}={} conflicts with SIRIX_SCENE={}, because it names the {} canonical workspace config directory",
            SIRIX_WORKSPACE_CONFIG_DIRNAME_ENV,
            trimmed,
            scene.as_str(),
            opposite.as_str()
        );
    }
    Ok(())
}

fn path_matches_canonical_scene(path: &PathBuf, scene: SirixScene) -> anyhow::Result<bool> {
    Ok(path == &canonical_home_for_scene(scene)?)
}

fn path_matches_scene_bin_home(path: &PathBuf, scene: SirixScene) -> anyhow::Result<bool> {
    let canonical_home = canonical_home_for_scene(scene)?;
    Ok(path.starts_with(canonical_home.join("bin")))
}

fn user_home_dir() -> anyhow::Result<PathBuf> {
    if let Some(home) = dirs::home_dir() {
        return Ok(home);
    }
    let home = env::var("HOME")
        .or_else(|_| env::var("USERPROFILE"))
        .or_else(|_| match (env::var("HOMEDRIVE"), env::var("HOMEPATH")) {
            (Ok(drive), Ok(path)) => Ok(format!("{drive}{path}")),
            _ => Err(env::VarError::NotPresent),
        })
        .context("failed to resolve user home dir")?;
    Ok(PathBuf::from(home))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scene_bin_paths_match_release_home() {
        let release_bin = canonical_home_for_scene(SirixScene::Release)
            .unwrap()
            .join("bin")
            .join("sirix");
        assert!(
            path_matches_scene_bin_home(&release_bin, SirixScene::Release).unwrap(),
            "release shim path should map back to the release scene"
        );
    }

    #[test]
    fn scene_bin_paths_match_debug_home() {
        let debug_bin = canonical_home_for_scene(SirixScene::Debug)
            .unwrap()
            .join("bin")
            .join("sirix");
        assert!(
            path_matches_scene_bin_home(&debug_bin, SirixScene::Debug).unwrap(),
            "debug shim path should map back to the debug scene"
        );
    }
}
