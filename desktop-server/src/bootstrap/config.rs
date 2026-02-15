use std::fs;

use serde::Deserialize;
use toml::{map::Map, Value};

#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    pub backend: BackendConfig,
    pub local_ws: LocalWsConfig,
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
}

#[derive(Debug, Clone, Deserialize)]
pub struct LocalWsConfig {
    pub host: String,
    pub port_range_start: u16,
    pub port_range_end: u16,
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

pub fn load_config() -> anyhow::Result<AppConfig> {
    let mut merged = read_toml("config.toml")?;
    apply_env_overrides(&mut merged, "DESKTOP__")?;
    Ok(merged.try_into()?)
}

fn read_toml(path: &str) -> anyhow::Result<Value> {
    let content = fs::read_to_string(path)?;
    Ok(content.parse::<Value>()?)
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
