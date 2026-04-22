#[path = "../cli_support.rs"]
mod cli_support;
#[path = "../scene.rs"]
mod scene;

use std::{
    env,
    io::{self, Write},
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

use crossterm::{cursor, execute, style, terminal::LeaveAlternateScreen};

use anyhow::Context;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use crossterm::terminal;
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use cli_support::{
    ensure_desktop_server, ensure_login_prompt, local_http_url, local_ws_url, spawn_stdin_reader,
    RawModeGuard, CURRENT_TERMINAL_ENV, CURRENT_TERMINAL_KIND_ENV, TERMINAL_KIND_HOSTED_SHELL,
};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("list") => list_sessions().await,
        Some("resume") => {
            if is_hosted_shell_terminal() {
                anyhow::bail!(
                    "`sirix resume` is not supported inside `sirix-terminal`; please resume from a system terminal or Sirix Desktop"
                );
            }
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
            let hosted_shell_terminal = is_hosted_shell_terminal();
            let launch = launch_session(
                port,
                (!hosted_shell_terminal)
                    .then_some(current_terminal_id.as_deref())
                    .flatten(),
            )
            .await?;
            if hosted_shell_terminal {
                print_detached_session_hint(&launch);
                Ok(())
            } else if launch.reuse_current_terminal {
                run_codex_in_current_terminal(&launch)
            } else {
                attach_session(port, &launch.terminal_id).await
            }
        }
    }
}

fn print_help() {
    println!(
        "sirix\n  sirix\n  sirix list\n  sirix resume <ai_session_id|terminal_id>\n\nRuns a Sirix AI coding session mirrored into Sirix."
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

struct LaunchSessionResult {
    ai_session_id: String,
    terminal_id: String,
    reuse_current_terminal: bool,
    current_terminal_launch: Option<CurrentTerminalLaunch>,
}

struct CurrentTerminalLaunch {
    codex_executable: String,
    workspace_root: String,
    codex_home: String,
    sirix_config_overrides_path: String,
    sirix_agent_runtime_path: String,
    sirix_exec_policy_path: String,
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
        request_body["reuse_terminal_id"] =
            serde_json::Value::String(reuse_terminal_id.to_string());
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
    let ai_session_id = payload
        .get("ai_session_id")
        .and_then(serde_json::Value::as_str)
        .map(ToString::to_string)
        .context("ai session response missing ai_session_id")?;
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
            sirix_config_overrides_path: item
                .get("sirix_config_overrides_path")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string(),
            sirix_agent_runtime_path: item
                .get("sirix_agent_runtime_path")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string(),
            sirix_exec_policy_path: item
                .get("sirix_exec_policy_path")
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
        ai_session_id,
        terminal_id,
        reuse_current_terminal,
        current_terminal_launch,
    })
}

fn is_hosted_shell_terminal() -> bool {
    env::var(CURRENT_TERMINAL_KIND_ENV)
        .ok()
        .is_some_and(|value| value.trim() == TERMINAL_KIND_HOSTED_SHELL)
}

fn print_detached_session_hint(launch: &LaunchSessionResult) {
    eprintln!(
        "[sirix] current terminal is a `sirix-terminal` hosted shell, so Sirix AI was created as a separate shared terminal instead of reusing this shell."
    );
    eprintln!("[sirix] ai_session_id={}", launch.ai_session_id);
    eprintln!("[sirix] terminal_id={}", launch.terminal_id);
    eprintln!(
        "[sirix] open it from Sirix Desktop/Mobile, or resume it from a system terminal with: sirix resume {}",
        launch.ai_session_id
    );
}

fn run_codex_in_current_terminal(launch: &LaunchSessionResult) -> anyhow::Result<()> {
    let current = launch
        .current_terminal_launch
        .as_ref()
        .context("current terminal launch payload missing")?;
    let resolved_executable = resolve_launch_executable(&current.codex_executable)?;

    let mut command = Command::new(&resolved_executable);
    command.current_dir(&current.workspace_root);
    if !current.codex_home.trim().is_empty() {
        command.env("CODEX_HOME", &current.codex_home);
    }
    if !current.sirix_config_overrides_path.trim().is_empty() {
        command.env(
            "SIRIX_CONFIG_OVERRIDES_PATH",
            &current.sirix_config_overrides_path,
        );
    }
    if !current.sirix_agent_runtime_path.trim().is_empty() {
        command.env(
            "SIRIX_AGENT_RUNTIME_PATH",
            &current.sirix_agent_runtime_path,
        );
    }
    if !current.sirix_exec_policy_path.trim().is_empty() {
        command.env("SIRIX_EXEC_POLICY_PATH", &current.sirix_exec_policy_path);
    }
    if let (Some(env_key), Some(api_key)) = (
        current.provider_api_key_env.as_deref(),
        current.provider_api_key.as_deref(),
    ) {
        if !env_key.trim().is_empty() && !api_key.trim().is_empty() {
            command.env(env_key, api_key);
        }
    }

    let status = command
        .status()
        .context("failed to spawn AI runtime in current terminal")?;
    restore_current_terminal_after_runtime_exit()?;
    if status.success() {
        return Ok(());
    }
    anyhow::bail!("AI runtime exited with status {status}");
}

fn restore_current_terminal_after_runtime_exit() -> anyhow::Result<()> {
    let mut stdout = io::stdout();
    execute!(
        stdout,
        LeaveAlternateScreen,
        cursor::Show,
        style::ResetColor
    )
    .context("failed to restore current terminal after AI runtime exit")?;
    stdout
        .write_all(
            b"[?1l>[?1000l[?1002l[?1003l[?1006l[?2004l[?7h[r[0m[?25h
",
        )
        .context("failed to write current terminal restore sequence")?;
    stdout.flush().ok();
    Ok(())
}

fn resolve_launch_executable(raw: &str) -> anyhow::Result<PathBuf> {
    let candidate = raw.trim();
    if candidate.is_empty() {
        anyhow::bail!("AI runtime executable path is empty");
    }

    let resolved = find_executable(candidate)
        .with_context(|| format!("AI runtime executable not found: {candidate}"))?;
    let metadata = std::fs::metadata(&resolved).with_context(|| {
        format!(
            "failed to stat AI runtime executable {}",
            resolved.display()
        )
    })?;
    if !metadata.is_file() {
        anyhow::bail!(
            "AI runtime executable is not a file: {}",
            resolved.display()
        );
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        if metadata.permissions().mode() & 0o111 == 0 {
            anyhow::bail!(
                "AI runtime executable is not executable: {}",
                resolved.display()
            );
        }
    }

    Ok(resolved)
}

fn find_executable(raw: &str) -> Option<PathBuf> {
    let candidate = Path::new(raw);
    if candidate.is_absolute() || candidate.components().count() > 1 {
        return candidate.is_file().then(|| candidate.to_path_buf());
    }

    let path = env::var_os("PATH")?;
    for directory in env::split_paths(&path) {
        let resolved = directory.join(candidate);
        if resolved.is_file() {
            return Some(resolved);
        }

        #[cfg(windows)]
        {
            let extensions = env::var_os("PATHEXT")
                .map(|value| env::split_paths(&value).collect::<Vec<_>>())
                .unwrap_or_default();
            for extension in extensions {
                let suffix = extension.to_string_lossy();
                let resolved = directory.join(format!("{raw}{suffix}"));
                if resolved.is_file() {
                    return Some(resolved);
                }
            }
        }
    }

    None
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
    let url = local_ws_url(port, "/ws");
    let (socket, _) = connect_async(url)
        .await
        .context("failed to connect local websocket")?;
    let (mut write, mut read) = socket.split();

    write
        .send(Message::Text(
            serde_json::json!({
                "type": "terminal.attach",
                "payload": {
                    "terminal_id": terminal_id,
                    "protocol_version": 1,
                    "sync_mode": "raw-v1",
                    "client_kind": "system_terminal",
                }
            })
            .to_string()
            .into(),
        ))
        .await
        .context("failed to attach terminal session")?;

    let raw_mode_guard = RawModeGuard::activate()?;
    let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    spawn_stdin_reader(stdin_tx);

    let mut stdout = io::stdout();
    let mut last_size = terminal::size().unwrap_or((120, 32));
    let mut viewer_presence_epoch: Option<u64> = None;
    let mut resize_tick = tokio::time::interval(Duration::from_millis(250));

    write_resize(&mut write, terminal_id, last_size, viewer_presence_epoch).await?;

    let attach_result: anyhow::Result<TerminalDetachReason> = loop {
        tokio::select! {
            Some(bytes) = stdin_rx.recv() => {
                if let Err(error) = write
                    .send(Message::Text(
                        serde_json::json!({
                            "type": "terminal.input",
                            "terminal_id": terminal_id,
                            "data_base64": BASE64.encode(bytes),
                        })
                        .to_string()
                        .into()
                    ))
                    .await
                {
                    break Err(anyhow::Error::new(error).context("failed to send terminal input"));
                }
            }
            _ = resize_tick.tick() => {
                let current_size = terminal::size().unwrap_or(last_size);
                if current_size != last_size {
                    last_size = current_size;
                    if let Err(error) = write_resize(
                        &mut write,
                        terminal_id,
                        current_size,
                        viewer_presence_epoch,
                    )
                    .await
                    {
                        break Err(error.context("failed to propagate terminal resize"));
                    }
                }
            }
            message = read.next() => {
                match message {
                    Some(Ok(Message::Text(text))) => {
                        if handle_terminal_message(&mut stdout, &text, &mut viewer_presence_epoch)? {
                            break Ok(TerminalDetachReason::SessionClosed);
                        }
                    }
                    Some(Ok(Message::Binary(bytes))) => {
                        if let Err(error) = stdout.write_all(&bytes) {
                            break Err(anyhow::Error::new(error).context("failed to write binary websocket frame"));
                        }
                        stdout.flush().ok();
                    }
                    Some(Ok(Message::Close(_))) | None => break Ok(TerminalDetachReason::TransportClosed),
                    Some(Ok(_)) => {}
                    Some(Err(error)) => break Err(anyhow::Error::new(error).context("terminal websocket read failed")),
                }
            }
        }
    };

    let detach_reason = match &attach_result {
        Ok(reason) => *reason,
        Err(_) => TerminalDetachReason::TransportClosed,
    };
    drop(raw_mode_guard);
    restore_local_terminal(&mut stdout, detach_reason)?;
    match attach_result {
        Ok(_) => Ok(()),
        Err(error) if is_graceful_terminal_disconnect(&error) => Ok(()),
        Err(error) => Err(error),
    }
}

async fn write_resize<S>(
    write: &mut S,
    terminal_id: &str,
    size: (u16, u16),
    viewer_presence_epoch: Option<u64>,
) -> anyhow::Result<()>
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
                "client_kind": "system_terminal",
                "viewer_presence_epoch": viewer_presence_epoch,
            })
            .to_string()
            .into(),
        ))
        .await
        .context("failed to send terminal resize")
}

#[derive(Clone, Copy, Debug)]
enum TerminalDetachReason {
    SessionClosed,
    TransportClosed,
}

fn is_graceful_terminal_disconnect(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        let message = cause.to_string().to_ascii_lowercase();
        message.contains("connection reset without closing handshake")
            || message.contains("broken pipe")
            || message.contains("connection reset by peer")
            || message.contains("sending after closing")
            || message.contains("io error: broken pipe")
    })
}

fn restore_local_terminal(
    stdout: &mut io::Stdout,
    reason: TerminalDetachReason,
) -> anyhow::Result<()> {
    // 共享终端通过 raw-v1 直接把远端 escape stream 镜像到当前系统终端。
    // 如果 desktop-server 被杀掉，远端可能来不及自行退出 alt screen / 恢复
    // 光标与颜色状态，导致用户返回本地 shell 后终端仍处于异常模式。
    // 这里在退出 Sirix 附着态时主动执行一次本地 terminal reset，确保系统
    // 终端可靠回到可交互状态。
    execute!(
        stdout,
        LeaveAlternateScreen,
        cursor::Show,
        style::ResetColor
    )
    .context("failed to restore local terminal state")?;
    stdout
        .write_all(
            b"\x1b[?1l\x1b>\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?7h\x1b[r\x1b[0m\x1b[?25h\r\n",
        )
        .context("failed to write local terminal reset sequence")?;
    match reason {
        TerminalDetachReason::SessionClosed => {
            stdout
                .write_all(b"[sirix] shared terminal closed.\r\n")
                .context("failed to write session closed message")?;
        }
        TerminalDetachReason::TransportClosed => {
            stdout
                .write_all(
                    b"[sirix] desktop-server disconnected; shared terminal detached safely.\r\n",
                )
                .context("failed to write transport closed message")?;
        }
    }
    stdout.flush().ok();
    Ok(())
}

fn handle_terminal_message(
    stdout: &mut io::Stdout,
    raw: &str,
    viewer_presence_epoch: &mut Option<u64>,
) -> anyhow::Result<bool> {
    let decoded = serde_json::from_str::<serde_json::Value>(raw)
        .with_context(|| format!("failed to decode websocket payload: {raw}"))?;
    let message_type = decoded
        .get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();

    match message_type {
        "terminal.ready" => {
            *viewer_presence_epoch = decoded
                .get("payload")
                .and_then(|payload| payload.get("viewer_presence_epoch"))
                .and_then(serde_json::Value::as_u64);
            Ok(false)
        }
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
