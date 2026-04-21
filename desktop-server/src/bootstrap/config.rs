use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::Deserialize;
use toml::{map::Map, Table, Value};

use crate::scene::{
    parse_scene, resolve_scene, SirixScene, SIRIX_DESKTOP_SERVER_CONFIG_PATH_ENV, SIRIX_SCENE_ENV,
};

#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    pub backend: BackendConfig,
    pub local_ws: LocalWsConfig,
    #[serde(default)]
    pub authorization: AuthorizationConfig,
    pub capture: CaptureConfig,
    pub stream: StreamConfig,
    pub logging: LoggingConfig,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BackendConfig {
    pub base_url: String,
    pub health_path: String,
    pub heartbeat_path: String,
    pub heartbeat_interval_seconds: u64,
    pub device_id: String,
    pub event_ws_path: String,
    pub session_decision_path: String,
    pub webrtc_signal_path: String,
    #[serde(default = "default_runtime_settings_path")]
    pub runtime_settings_path: String,
    #[serde(default = "default_runtime_logs_path")]
    pub runtime_logs_path: String,
    #[serde(default = "default_pending_sessions_path")]
    pub pending_sessions_path: String,
    #[serde(default = "default_screen_state_path")]
    pub screen_state_path: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LocalWsConfig {
    pub host: String,
    pub port_range_start: u16,
    pub port_range_end: u16,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuthorizationConfig {
    #[serde(default = "default_manual_approve_timeout_seconds")]
    pub manual_approve_timeout_seconds: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CaptureConfig {
    pub snapshot_interval_seconds: u64,
    pub snapshot_width: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StreamConfig {
    pub default_profile: String,
    pub default_fps: u8,
    pub auto_adapt: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LoggingConfig {
    pub level: String,
    pub json: bool,
}

impl Default for AuthorizationConfig {
    fn default() -> Self {
        Self {
            manual_approve_timeout_seconds: default_manual_approve_timeout_seconds(),
        }
    }
}

pub fn load_config() -> anyhow::Result<AppConfig> {
    let scene = resolve_scene()?;
    let (mut merged, used_explicit_config_path) = load_shared_config_document()?;
    apply_scene_defaults(&mut merged, scene, !used_explicit_config_path);
    apply_env_overrides(&mut merged, "DESKTOP__")?;
    apply_sirix_runtime_overrides(&mut merged, scene)?;
    Ok(merged.try_into()?)
}

fn load_shared_config_document() -> anyhow::Result<(Value, bool)> {
    if let Ok(explicit_path) = std::env::var(SIRIX_DESKTOP_SERVER_CONFIG_PATH_ENV) {
        let trimmed = explicit_path.trim();
        if !trimmed.is_empty() {
            return Ok((read_toml(trimmed)?, true));
        }
    }

    if let Some(default_path) = discover_shared_config_path() {
        return Ok((read_toml(default_path.as_path())?, false));
    }

    Ok((
        Value::Table(
            toml::from_str::<Table>(include_str!("../../config.toml"))
                .context("failed to parse embedded desktop-server config")?,
        ),
        false,
    ))
}

fn default_screen_state_path() -> String {
    "/api/v1/desktop/devices/{device_id}/screen-state".to_string()
}

fn default_runtime_settings_path() -> String {
    "/api/v1/runtime/settings".to_string()
}

fn default_runtime_logs_path() -> String {
    "/api/v1/runtime/logs".to_string()
}

fn default_pending_sessions_path() -> String {
    "/api/v1/desktop/devices/{device_id}/pending-sessions".to_string()
}

fn default_manual_approve_timeout_seconds() -> u64 {
    120
}

fn read_toml(path: impl AsRef<Path>) -> anyhow::Result<Value> {
    let content = fs::read_to_string(path.as_ref())?;
    // `toml` 0.9 no longer treats `Value` parsing as "parse a full TOML document".
    // Desktop Server config files are document-style TOML with top-level tables
    // such as `[backend]`, so parse the full document as a table explicitly.
    Ok(Value::Table(toml::from_str::<Table>(&content)?))
}

fn discover_shared_config_path() -> Option<PathBuf> {
    std::env::current_exe().ok().and_then(|current_exe| {
        current_exe
            .ancestors()
            .skip(1)
            .map(|ancestor| ancestor.join("config.toml"))
            .find(|candidate| candidate.is_file())
    })
}

fn apply_env_overrides(root: &mut Value, prefix: &str) -> anyhow::Result<()> {
    let mut keys = std::env::vars()
        .filter(|(key, _)| key.starts_with(prefix))
        .collect::<Vec<(String, String)>>();

    keys.sort_by(|(left, _), (right, _)| left.cmp(right));

    for (key, raw_value) in keys {
        let path = key
            .trim_start_matches(prefix)
            .split("__")
            .map(|segment| segment.to_ascii_lowercase())
            .collect::<Vec<_>>();

        if path.is_empty() {
            continue;
        }

        let value = parse_env_value(&raw_value)?;
        set_nested_value(root, &path, value);
    }

    Ok(())
}

fn parse_env_value(raw: &str) -> anyhow::Result<Value> {
    let trimmed = raw.trim();

    if trimmed.starts_with('[') || trimmed.starts_with('{') {
        let parsed_json = serde_json::from_str::<serde_json::Value>(trimmed)?;
        return json_to_toml_value(parsed_json);
    }

    if trimmed.starts_with('"') && trimmed.ends_with('"') {
        return Ok(Value::String(trimmed[1..trimmed.len() - 1].to_string()));
    }

    if let Ok(parsed) = trimmed.parse::<bool>() {
        return Ok(Value::Boolean(parsed));
    }

    if let Ok(parsed) = trimmed.parse::<i64>() {
        return Ok(Value::Integer(parsed));
    }

    if let Ok(parsed) = trimmed.parse::<f64>() {
        return Ok(Value::Float(parsed));
    }

    Ok(Value::String(trimmed.to_string()))
}

fn apply_scene_defaults(root: &mut Value, scene: SirixScene, override_scene_sensitive: bool) {
    if override_scene_sensitive {
        set_nested_value(
            root,
            &["backend".to_string(), "base_url".to_string()],
            Value::String(format!("http://127.0.0.1:{}", scene.default_backend_port())),
        );
        set_nested_value(
            root,
            &["backend".to_string(), "device_id".to_string()],
            Value::String(scene.default_device_id().to_string()),
        );
        set_nested_value(
            root,
            &["local_ws".to_string(), "port_range_start".to_string()],
            Value::Integer(scene.default_local_ws_port_start() as i64),
        );
        set_nested_value(
            root,
            &["local_ws".to_string(), "port_range_end".to_string()],
            Value::Integer(scene.default_local_ws_port_end() as i64),
        );
    }
}

fn apply_sirix_runtime_overrides(root: &mut Value, scene: SirixScene) -> anyhow::Result<()> {
    if let Ok(explicit_scene) = std::env::var(SIRIX_SCENE_ENV) {
        if parse_scene(&explicit_scene).is_none() {
            anyhow::bail!("unsupported {} value: {}", SIRIX_SCENE_ENV, explicit_scene);
        }
    }

    if let Ok(api_base_url) = std::env::var("SIRIX_API_BASE_URL") {
        if !api_base_url.trim().is_empty() {
            set_nested_value(
                root,
                &["backend".to_string(), "base_url".to_string()],
                Value::String(api_base_url),
            );
        }
    } else if let Ok(server_host) = std::env::var("SIRIX_SERVER_HOST") {
        if !server_host.trim().is_empty() {
            set_nested_value(
                root,
                &["backend".to_string(), "base_url".to_string()],
                Value::String(format!(
                    "http://{}:{}",
                    server_host.trim(),
                    scene.default_backend_port()
                )),
            );
        }
    }

    if let Ok(host) = std::env::var("SIRIX_DESKTOP_SERVER_HOST") {
        if !host.trim().is_empty() {
            set_nested_value(
                root,
                &["local_ws".to_string(), "host".to_string()],
                Value::String(host),
            );
        }
    }

    if let Ok(start) = std::env::var("SIRIX_DESKTOP_SERVER_PORT_START") {
        if let Ok(parsed) = start.trim().parse::<u16>() {
            set_nested_value(
                root,
                &["local_ws".to_string(), "port_range_start".to_string()],
                Value::Integer(parsed as i64),
            );
        }
    }

    if let Ok(end) = std::env::var("SIRIX_DESKTOP_SERVER_PORT_END") {
        if let Ok(parsed) = end.trim().parse::<u16>() {
            set_nested_value(
                root,
                &["local_ws".to_string(), "port_range_end".to_string()],
                Value::Integer(parsed as i64),
            );
        }
    }

    Ok(())
}

fn json_to_toml_value(value: serde_json::Value) -> anyhow::Result<Value> {
    match value {
        serde_json::Value::Null => Err(anyhow::anyhow!("null is not supported in env override")),
        serde_json::Value::Bool(value) => Ok(Value::Boolean(value)),
        serde_json::Value::Number(value) => {
            if let Some(value) = value.as_i64() {
                return Ok(Value::Integer(value));
            }

            if let Some(value) = value.as_u64() {
                return Ok(Value::Integer(value as i64));
            }

            let Some(value) = value.as_f64() else {
                return Err(anyhow::anyhow!("unsupported number in env override"));
            };

            Ok(Value::Float(value))
        }
        serde_json::Value::String(value) => Ok(Value::String(value)),
        serde_json::Value::Array(values) => {
            let mut converted = Vec::with_capacity(values.len());
            for value in values {
                converted.push(json_to_toml_value(value)?);
            }
            Ok(Value::Array(converted))
        }
        serde_json::Value::Object(values) => {
            let mut converted = Map::new();
            for (key, value) in values {
                converted.insert(key, json_to_toml_value(value)?);
            }
            Ok(Value::Table(converted))
        }
    }
}

fn set_nested_value(root: &mut Value, path: &[String], value: Value) {
    if !matches!(root, Value::Table(_)) {
        *root = Value::Table(Map::new());
    }

    if let Value::Table(table) = root {
        if path.len() == 1 {
            table.insert(path[0].clone(), value);
            return;
        }

        let entry = table
            .entry(path[0].clone())
            .or_insert_with(|| Value::Table(Map::new()));
        set_nested_value(entry, &path[1..], value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_scene_defaults_overrides_scene_sensitive_fields_for_debug() {
        let mut root =
            Value::Table(toml::from_str::<Table>(include_str!("../../config.toml")).unwrap());
        apply_scene_defaults(&mut root, SirixScene::Debug, true);
        let config: AppConfig = root.try_into().expect("debug config should deserialize");

        assert_eq!(config.backend.base_url, "http://127.0.0.1:46110");
        assert_eq!(
            config.backend.device_id,
            SirixScene::Debug.default_device_id()
        );
        assert_eq!(config.local_ws.port_range_start, 46111);
        assert_eq!(config.local_ws.port_range_end, 46119);
    }

    #[test]
    fn apply_scene_defaults_overrides_scene_sensitive_fields_for_release() {
        let mut root =
            Value::Table(toml::from_str::<Table>(include_str!("../../config.toml")).unwrap());
        apply_scene_defaults(&mut root, SirixScene::Release, true);
        let config: AppConfig = root.try_into().expect("release config should deserialize");

        assert_eq!(config.backend.base_url, "http://127.0.0.1:46120");
        assert_eq!(
            config.backend.device_id,
            SirixScene::Release.default_device_id()
        );
        assert_eq!(config.local_ws.port_range_start, 46121);
        assert_eq!(config.local_ws.port_range_end, 46129);
    }
}
