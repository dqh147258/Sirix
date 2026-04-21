use std::{
    env,
    io::{self, Read, Write},
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::Duration,
};

use anyhow::Context;
use crossterm::terminal;
use reqwest::StatusCode;

use crate::scene::{
    resolve_scene, SirixScene, SIRIX_SCENE_ENV,
};

const DEFAULT_LOCAL_HOST: &str = "127.0.0.1";

pub(crate) const CURRENT_TERMINAL_ENV: &str = "SIRIX_TERMINAL_SESSION_ID";
pub(crate) const CURRENT_TERMINAL_KIND_ENV: &str = "SIRIX_TERMINAL_KIND";
pub(crate) const TERMINAL_KIND_HOSTED_SHELL: &str = "hosted_shell";

pub(crate) async fn ensure_desktop_server() -> anyhow::Result<u16> {
    if let Some(port) = probe_running_port().await? {
        return Ok(port);
    }

    start_desktop_server()?;

    let deadline = std::time::Instant::now() + Duration::from_secs(8);
    while std::time::Instant::now() < deadline {
        if let Some(port) = probe_running_port().await? {
            return Ok(port);
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    anyhow::bail!("desktop-server did not become healthy after autostart")
}

pub(crate) async fn ensure_login_prompt(port: u16) -> anyhow::Result<()> {
    let session_url = local_http_url(port, "/auth/session");
    let response = reqwest::get(&session_url)
        .await
        .context("failed to query local auth session")?;
    if response.status() == StatusCode::NO_CONTENT {
        let should_login = prompt_yes_no("Sirix 当前未登录，是否现在登录？ [Y/n]: ", true)?;
        if should_login {
            let username = prompt_line("用户名: ")?;
            let password = prompt_line("密码: ")?;
            let login_payload = serde_json::json!({
                "username": username,
                "password": password,
            });
            let client = reqwest::Client::new();
            let login_response = client
                .post(local_http_url(port, "/auth/session"))
                .json(&login_payload)
                .send()
                .await
                .context("failed to submit local login")?;
            if !login_response.status().is_success() {
                let should_register =
                    prompt_yes_no("登录失败，是否尝试注册并继续？ [Y/n]: ", true)?;
                if should_register {
                    client
                        .post(local_http_url(port, "/auth/register"))
                        .json(&login_payload)
                        .send()
                        .await
                        .context("failed to submit local registration")?
                        .error_for_status()
                        .context("registration failed")?;
                }
            }
        }
    }
    Ok(())
}

pub(crate) fn local_http_url(port: u16, path: &str) -> String {
    format!("http://{}:{}{}", local_host(), port, path)
}

pub(crate) fn local_ws_url(port: u16, path: &str) -> String {
    format!("ws://{}:{}{}", local_host(), port, path)
}

pub(crate) fn local_host() -> String {
    env::var("SIRIX_DESKTOP_SERVER_HOST").unwrap_or_else(|_| DEFAULT_LOCAL_HOST.to_string())
}

pub(crate) fn spawn_stdin_reader(tx: tokio::sync::mpsc::UnboundedSender<Vec<u8>>) {
    thread::spawn(move || {
        let mut stdin = io::stdin();
        loop {
            let mut buffer = [0_u8; 4096];
            match stdin.read(&mut buffer) {
                Ok(0) => break,
                Ok(read_len) => {
                    if tx.send(buffer[..read_len].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
}

pub(crate) fn prompt_yes_no(prompt: &str, default_yes: bool) -> anyhow::Result<bool> {
    let input = prompt_line(prompt)?;
    let trimmed = input.trim().to_ascii_lowercase();
    if trimmed.is_empty() {
        return Ok(default_yes);
    }
    Ok(matches!(trimmed.as_str(), "y" | "yes"))
}

pub(crate) fn prompt_line(prompt: &str) -> anyhow::Result<String> {
    print!("{prompt}");
    io::stdout().flush().ok();
    let mut input = String::new();
    io::stdin()
        .read_line(&mut input)
        .context("failed to read prompt input")?;
    Ok(input.trim().to_string())
}

pub(crate) struct RawModeGuard;

impl RawModeGuard {
    pub(crate) fn activate() -> anyhow::Result<Self> {
        terminal::enable_raw_mode().context("failed to enable raw mode")?;
        Ok(Self)
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = terminal::disable_raw_mode();
    }
}

async fn probe_running_port() -> anyhow::Result<Option<u16>> {
    for port in port_range() {
        let response = reqwest::get(local_http_url(port, "/health")).await;
        if let Ok(response) = response {
            if response.status().is_success() {
                return Ok(Some(port));
            }
        }
    }
    Ok(None)
}

fn start_desktop_server() -> anyhow::Result<()> {
    let desktop_server = sibling_binary_path("desktop-server")?;
    let scene = resolve_scene()?;
    let mut command = Command::new(desktop_server);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .env(SIRIX_SCENE_ENV, scene.as_str());
    command
        .spawn()
        .context("failed to autostart desktop-server")?;
    Ok(())
}

fn sibling_binary_path(binary_name: &str) -> anyhow::Result<PathBuf> {
    let current_exe = env::current_exe().context("failed to resolve current executable path")?;
    let parent = current_exe
        .parent()
        .context("current executable has no parent directory")?;
    let executable_name = if cfg!(windows) {
        format!("{binary_name}.exe")
    } else {
        binary_name.to_string()
    };
    let resolved = parent.join(executable_name);
    if !resolved.exists() {
        anyhow::bail!("required sibling binary not found: {}", resolved.display());
    }
    Ok(resolved)
}

fn port_range() -> std::ops::RangeInclusive<u16> {
    let scene = resolve_scene().unwrap_or(SirixScene::Debug);
    let start = env::var("SIRIX_DESKTOP_SERVER_PORT_START")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(scene.default_local_ws_port_start());
    let end = env::var("SIRIX_DESKTOP_SERVER_PORT_END")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(scene.default_local_ws_port_end());
    start..=end.max(start)
}
