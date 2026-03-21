use std::{fs, path::Path};

use serde::Deserialize;
use toml::{map::Map, Value};

use crate::application::runtime_logging::ENABLE_RUNTIME_LOGGING;

#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    pub server: ServerConfig,
    pub logging: LoggingConfig,
    pub runtime: RuntimeConfig,
    pub postgres: PostgresConfig,
    pub redis: RedisConfig,
    pub auth: AuthConfig,
    pub webrtc: WebrtcConfig,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LoggingConfig {
    pub level: String,
    pub json: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RuntimeConfig {
    #[serde(default = "default_logging_enabled")]
    pub logging_enabled: bool,
    #[serde(default = "default_logs_root_dir")]
    pub logs_root_dir: String,
    #[serde(default = "default_max_run_directories")]
    pub max_run_directories: usize,
    #[serde(default = "default_max_lines_per_file")]
    pub max_lines_per_file: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PostgresConfig {
    pub url: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RedisConfig {
    pub url: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuthConfig {
    pub access_token_ttl_minutes: i64,
    pub refresh_token_ttl_days: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WebrtcConfig {
    pub ice_servers: Vec<String>,
}

fn default_logging_enabled() -> bool {
    ENABLE_RUNTIME_LOGGING
}

fn default_logs_root_dir() -> String {
    "runtime-logs".to_string()
}

fn default_max_run_directories() -> usize {
    10
}

fn default_max_lines_per_file() -> usize {
    5000
}

pub fn load_config() -> anyhow::Result<AppConfig> {
    let env = std::env::var("APP_ENV").unwrap_or_else(|_| "dev".to_string());

    let mut merged = read_toml("config/default.toml")?;
    let env_path = format!("config/{env}.toml");
    if Path::new(&env_path).exists() {
        let env_value = read_toml(&env_path)?;
        merge_values(&mut merged, env_value);
    }

    apply_env_overrides(&mut merged, "APP__")?;

    Ok(merged.try_into()?)
}

fn read_toml(path: &str) -> anyhow::Result<Value> {
    let content = fs::read_to_string(path)?;
    Ok(content.parse::<Value>()?)
}

fn merge_values(base: &mut Value, override_value: Value) {
    match (base, override_value) {
        (Value::Table(base_table), Value::Table(override_table)) => {
            for (key, value) in override_table {
                match base_table.get_mut(&key) {
                    Some(base_value) => merge_values(base_value, value),
                    None => {
                        base_table.insert(key, value);
                    }
                }
            }
        }
        (base_slot, override_value) => {
            *base_slot = override_value;
        }
    }
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
