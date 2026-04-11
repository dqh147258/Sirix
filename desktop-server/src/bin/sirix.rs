use std::{
    env,
    io::{self, Read, Write},
    process::{Command, Stdio},
    thread,
    time::Duration,
};

use anyhow::Context;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use crossterm::terminal;
use futures_util::{SinkExt, StreamExt};
use reqwest::StatusCode;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

const DEFAULT_LOCAL_HOST: &str = "127.0.0.1";
const DEFAULT_PORT_START: u16 = 9700;
const DEFAULT_PORT_END: u16 = 9710;
const CURRENT_TERMINAL_ENV: &str = "SIRIX_TERMINAL_SESSION_ID";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("list") => list_sessions().await,
        Some("resume") => {
            let session_or_terminal_id = args
                .next()
                .context("usage: sirix resume <ai_session_id|terminal_id>")?;
            let port = ensure_desktop_server().await?;
            ensure_login_prompt(port).await?;
            let terminal_id = resolve_terminal_id(port, &session_or_terminal_id).await?;
            attach_session(port, &terminal_id).await
        }
        Some("help") | Some("--help") | Some("-h") => {
            print_help();
            Ok(())
        }
        _ => {
            let port = ensure_desktop_server().await?;
            ensure_login_prompt(port).await?;
            let current_terminal_id = env::var(CURRENT_TERMINAL_ENV).ok();
            let launch = launch_session(port, current_terminal_id.as_deref()).await?;
            if launch.reuse_current_terminal {
                run_codex_in_current_terminal(&launch)
            } else {
                attach_session(port, &launch.terminal_id).await
            }
        }
    }
}

fn print_help() {
    println!(
        "sirix\n  sirix\n  sirix list\n  sirix resume <ai_session_id|terminal_id>\n\nRuns a Codex-backed AI coding session mirrored into Sirix."
    );
}

async fn list_sessions() -> anyhow::Result<()> {
    let port = ensure_desktop_server().await?;
    let url = local_http_url(port, "/ai/sessions");
    let response = reqwest::get(url)
        .await
        .context("failed to query local ai sessions")?;
    let response = response
        .error_for_status()
        .context("failed to load ai sessions")?;
    let payload = response
        .json::<serde_json::Value>()
        .await
        .context("failed to decode ai sessions")?;
    if let Some(items) = payload.as_array() {
        for item in items {
            let ai_session_id = item
                .get("ai_session_id")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("-");
            let terminal_id = item
                .get("terminal_id")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("-");
            let cwd = item
                .get("cwd")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("-");
            let agent = item
                .get("agent_id")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("-");
            println!("{ai_session_id}\t{terminal_id}\t{agent}\t{cwd}");
        }
    }
    Ok(())
}

async fn ensure_desktop_server() -> anyhow::Result<u16> {
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
    let current_exe = env::current_exe().context("failed to resolve sirix executable path")?;
    let parent = current_exe
        .parent()
        .context("sirix executable has no parent directory")?;
    let desktop_server_name = if cfg!(windows) {
        "desktop-server.exe"
    } else {
        "desktop-server"
    };
    let desktop_server = parent.join(desktop_server_name);
    if !desktop_server.exists() {
        anyhow::bail!(
            "desktop-server binary not found next to sirix: {}",
            desktop_server.display()
        );
    }

    Command::new(desktop_server)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to autostart desktop-server")?;
    Ok(())
}

async fn ensure_login_prompt(port: u16) -> anyhow::Result<()> {
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

struct LaunchSessionResult {
    terminal_id: String,
    reuse_current_terminal: bool,
    current_terminal_launch: Option<CurrentTerminalLaunch>,
}

struct CurrentTerminalLaunch {
    codex_executable: String,
    workspace_root: String,
    codex_home: String,
    provider_api_key_env: Option<String>,
    provider_api_key: Option<String>,
}

async fn launch_session(
    port: u16,
    reuse_terminal_id: Option<&str>,
) -> anyhow::Result<LaunchSessionResult> {
    let cwd = env::current_dir().context("failed to resolve current directory")?;
    let (cols, rows) = terminal::size().unwrap_or((120, 32));
    let client = reqwest::Client::new();
    let mut request_body = serde_json::json!({
        "cwd": cwd,
        "cols": cols,
        "rows": rows,
    });
    if let Some(reuse_terminal_id) = reuse_terminal_id.filter(|value| !value.trim().is_empty()) {
        request_body["reuse_terminal_id"] = serde_json::Value::String(reuse_terminal_id.to_string());
    }
    let response = client
        .post(local_http_url(port, "/ai/sessions"))
        .json(&request_body)
        .send()
        .await
        .context("failed to launch local ai session")?
        .error_for_status()
        .context("failed to create ai session")?;
    let payload = response
        .json::<serde_json::Value>()
        .await
        .context("failed to decode ai session response")?;
    let terminal_id = payload
        .get("terminal_id")
        .and_then(serde_json::Value::as_str)
        .map(ToString::to_string)
        .context("ai session response missing terminal_id")?;
    let reuse_current_terminal = payload
        .get("reuse_current_terminal")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let current_terminal_launch = payload
        .get("current_terminal_launch")
        .and_then(serde_json::Value::as_object)
        .map(|item| CurrentTerminalLaunch {
            codex_executable: item
                .get("codex_executable")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("codex")
                .to_string(),
            workspace_root: item
                .get("workspace_root")
                .and_then(serde_json::Value::as_str)
                .unwrap_or(".")
                .to_string(),
            codex_home: item
                .get("codex_home")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string(),
            provider_api_key_env: item
                .get("provider_api_key_env")
                .and_then(serde_json::Value::as_str)
                .map(ToString::to_string),
            provider_api_key: item
                .get("provider_api_key")
                .and_then(serde_json::Value::as_str)
                .map(ToString::to_string),
        });
    Ok(LaunchSessionResult {
        terminal_id,
        reuse_current_terminal,
        current_terminal_launch,
    })
}

fn run_codex_in_current_terminal(launch: &LaunchSessionResult) -> anyhow::Result<()> {
    let current = launch
        .current_terminal_launch
        .as_ref()
        .context("current terminal launch payload missing")?;

    let mut command = Command::new(&current.codex_executable);
    command.arg("--config");
    command.arg("approval_policy=\"never\"");
    command.current_dir(&current.workspace_root);
    if !current.codex_home.trim().is_empty() {
        command.env("CODEX_HOME", &current.codex_home);
    }
    if let (Some(env_key), Some(api_key)) = (
        current.provider_api_key_env.as_deref(),
        current.provider_api_key.as_deref(),
    ) {
        if !env_key.trim().is_empty() && !api_key.trim().is_empty() {
            command.env(env_key, api_key);
        }
    }

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let error = command.exec();
        return Err(error).context("failed to exec codex in current terminal");
    }

    #[cfg(not(unix))]
    {
        let status = command.status().context("failed to spawn codex in current terminal")?;
        if status.success() {
            return Ok(());
        }
        anyhow::bail!("codex exited with status {status}");
    }
}

async fn resolve_terminal_id(port: u16, session_or_terminal_id: &str) -> anyhow::Result<String> {
    let mut url = reqwest::Url::parse(&local_http_url(port, "/ai/sessions/resolve"))
        .context("failed to build local resolve url")?;
    url.query_pairs_mut()
        .append_pair("id", session_or_terminal_id);
    let response = reqwest::get(url)
        .await
        .context("failed to resolve ai session id locally")?;
    if response.status().is_success() {
        let payload = response
            .json::<serde_json::Value>()
            .await
            .context("failed to decode ai session resolve response")?;
        if let Some(terminal_id) = payload
            .get("terminal_id")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string)
        {
            return Ok(terminal_id);
        }
    }
    Ok(session_or_terminal_id.to_string())
}

async fn attach_session(port: u16, terminal_id: &str) -> anyhow::Result<()> {
    let url = format!("ws://{}:{}/ws", local_host(), port);
    let (socket, _) = connect_async(url)
        .await
        .context("failed to connect local websocket")?;
    let (mut write, mut read) = socket.split();

    write
        .send(Message::Text(
            serde_json::json!({
                "type": "terminal.attach",
                "terminal_id": terminal_id,
            })
            .to_string(),
        ))
        .await
        .context("failed to attach terminal session")?;

    let _raw_mode_guard = RawModeGuard::activate()?;
    let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    spawn_stdin_reader(stdin_tx);

    let mut stdout = io::stdout();
    let mut last_size = terminal::size().unwrap_or((120, 32));
    let mut resize_tick = tokio::time::interval(Duration::from_millis(250));

    write_resize(&mut write, terminal_id, last_size).await?;

    loop {
        tokio::select! {
            Some(bytes) = stdin_rx.recv() => {
                write
                    .send(Message::Text(
                        serde_json::json!({
                            "type": "terminal.input",
                            "terminal_id": terminal_id,
                            "data_base64": BASE64.encode(bytes),
                        }).to_string()
                    ))
                    .await
                    .context("failed to send terminal input")?;
            }
            _ = resize_tick.tick() => {
                let current_size = terminal::size().unwrap_or(last_size);
                if current_size != last_size {
                    last_size = current_size;
                    write_resize(&mut write, terminal_id, current_size).await?;
                }
            }
            message = read.next() => {
                match message {
                    Some(Ok(Message::Text(text))) => {
                        if handle_terminal_message(&mut stdout, &text)? {
                            break;
                        }
                    }
                    Some(Ok(Message::Binary(bytes))) => {
                        stdout.write_all(&bytes).context("failed to write binary websocket frame")?;
                        stdout.flush().ok();
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(error)) => return Err(error).context("terminal websocket read failed"),
                }
            }
        }
    }

    Ok(())
}

async fn write_resize<S>(write: &mut S, terminal_id: &str, size: (u16, u16)) -> anyhow::Result<()>
where
    S: futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    write
        .send(Message::Text(
            serde_json::json!({
                "type": "terminal.resize",
                "terminal_id": terminal_id,
                "cols": size.0,
                "rows": size.1,
            })
            .to_string(),
        ))
        .await
        .context("failed to send terminal resize")
}

fn handle_terminal_message(stdout: &mut io::Stdout, raw: &str) -> anyhow::Result<bool> {
    let decoded = serde_json::from_str::<serde_json::Value>(raw)
        .with_context(|| format!("failed to decode websocket payload: {raw}"))?;
    let message_type = decoded
        .get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();

    match message_type {
        "terminal.output" | "terminal.snapshot" => {
            if let Some(data) = decoded
                .get("payload")
                .and_then(|payload| payload.get("data_base64"))
                .and_then(serde_json::Value::as_str)
            {
                let bytes = BASE64
                    .decode(data)
                    .context("failed to decode terminal frame")?;
                stdout
                    .write_all(&bytes)
                    .context("failed to write terminal output")?;
                stdout.flush().ok();
            }
            Ok(false)
        }
        "terminal.error" => {
            if let Some(message) = decoded
                .get("payload")
                .and_then(|payload| payload.get("error_message"))
                .and_then(serde_json::Value::as_str)
            {
                eprintln!("\n[sirix] terminal error: {message}");
            }
            Ok(true)
        }
        "terminal.closed" => Ok(true),
        _ => Ok(false),
    }
}

fn spawn_stdin_reader(tx: tokio::sync::mpsc::UnboundedSender<Vec<u8>>) {
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

fn prompt_yes_no(prompt: &str, default_yes: bool) -> anyhow::Result<bool> {
    let input = prompt_line(prompt)?;
    let trimmed = input.trim().to_ascii_lowercase();
    if trimmed.is_empty() {
        return Ok(default_yes);
    }
    Ok(matches!(trimmed.as_str(), "y" | "yes"))
}

fn prompt_line(prompt: &str) -> anyhow::Result<String> {
    print!("{prompt}");
    io::stdout().flush().ok();
    let mut input = String::new();
    io::stdin()
        .read_line(&mut input)
        .context("failed to read prompt input")?;
    Ok(input.trim().to_string())
}

fn local_http_url(port: u16, path: &str) -> String {
    format!("http://{}:{}{}", local_host(), port, path)
}

fn local_host() -> String {
    env::var("SIRIX_DESKTOP_SERVER_HOST").unwrap_or_else(|_| DEFAULT_LOCAL_HOST.to_string())
}

fn port_range() -> std::ops::RangeInclusive<u16> {
    let start = env::var("SIRIX_DESKTOP_SERVER_PORT_START")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT_START);
    let end = env::var("SIRIX_DESKTOP_SERVER_PORT_END")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT_END);
    start..=end.max(start)
}

struct RawModeGuard;

impl RawModeGuard {
    fn activate() -> anyhow::Result<Self> {
        terminal::enable_raw_mode().context("failed to enable raw mode")?;
        Ok(Self)
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = terminal::disable_raw_mode();
    }
}
