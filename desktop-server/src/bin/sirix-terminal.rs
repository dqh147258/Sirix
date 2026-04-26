#[path = "../cli_approval.rs"]
mod cli_approval;
#[path = "../cli_support.rs"]
mod cli_support;
#[path = "../scene.rs"]
mod scene;
#[path = "../shared_terminal_protocol.rs"]
mod shared_terminal_protocol;
#[path = "../terminal_launch.rs"]
mod terminal_launch;

use std::{
    env,
    io::{self, Write},
};

use anyhow::Context;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use crossterm::{
    cursor, execute, style,
    terminal::{Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen},
};
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use uuid::Uuid;

use cli_approval::CliApprovalPrompt;
use cli_support::{
    current_terminal_size, ensure_desktop_server, ensure_login_prompt, local_http_url,
    local_ws_url, spawn_stdin_reader, spawn_terminal_size_watcher, RawModeGuard, TerminalSize,
    CURRENT_TERMINAL_ENV,
};
use shared_terminal_protocol::{RAW_STREAM_PROTOCOL_VERSION, RAW_STREAM_SYNC_MODE};

#[derive(Debug, serde::Deserialize)]
struct LocalSettingsSnapshot {
    prefer_tmux_terminal: Option<bool>,
}

#[derive(Debug, serde::Serialize)]
struct CreateLocalTerminalSessionRequest<'a> {
    cwd: &'a str,
    shell: &'a str,
    title: &'a str,
    cols: u16,
    rows: u16,
}

#[derive(Debug, serde::Deserialize)]
struct CreateLocalTerminalSessionResponse {
    terminal_id: Uuid,
    mirrored_to_backend: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    if env::var(CURRENT_TERMINAL_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .is_some_and(|value| !value.is_empty())
    {
        anyhow::bail!("`sirix-terminal` cannot run inside a Sirix-managed terminal session");
    }

    let port = ensure_desktop_server().await?;
    ensure_login_prompt(port).await?;
    maybe_warn_tmux_recommendation(port).await;

    let cwd = env::current_dir().context("failed to resolve current directory")?;
    let cwd_string = cwd.display().to_string();
    let initial_size = current_terminal_size(TerminalSize::new(120, 32));
    let shell = resolve_shared_shell();
    let session = create_local_terminal_session(
        port,
        cwd_string.as_str(),
        shell.as_str(),
        "Sirix Terminal",
        initial_size.cols,
        initial_size.rows,
    )
    .await?;

    eprintln!(
        "[sirix-terminal] attached terminal_id={} mirrored_to_backend={} mode=server_owned_runtime",
        session.terminal_id, session.mirrored_to_backend
    );

    // 关键语义变更：sirix-terminal 不再自己启动/持有 PTY 或 tmux。
    // 这里改成只创建 server-owned terminal runtime，然后把当前系统终端
    // 当作一个 system_terminal viewer attach 到 desktop-server。
    let (attached_once, attach_result) =
        attach_session(port, &session.terminal_id.to_string()).await;
    if !attached_once {
        if let Err(cleanup_error) = close_local_terminal_session(port, session.terminal_id).await {
            eprintln!(
                "[sirix-terminal] failed to cleanup unattached terminal {} after attach did not reach ready: {}",
                session.terminal_id, cleanup_error
            );
        }
    }
    attach_result
}

async fn maybe_warn_tmux_recommendation(port: u16) {
    let prefer_tmux = resolve_prefer_tmux_terminal(port).await;
    if !prefer_tmux || cfg!(windows) {
        return;
    }
    let probe = terminal_launch::cached_tmux_availability();
    if probe.available {
        return;
    }
    let warning = terminal_launch::build_tmux_missing_warning();
    terminal_launch::emit_warning_to_stderr("sirix-terminal", &warning);
}

async fn resolve_prefer_tmux_terminal(port: u16) -> bool {
    if let Some(override_value) = terminal_launch::prefer_tmux_env_override() {
        return override_value;
    }

    let default_value = terminal_launch::default_prefer_tmux_terminal();
    let response = reqwest::get(local_http_url(port, "/settings")).await;
    let Ok(response) = response else {
        return default_value;
    };
    let Ok(response) = response.error_for_status() else {
        return default_value;
    };
    match response.json::<LocalSettingsSnapshot>().await {
        Ok(payload) => payload.prefer_tmux_terminal.unwrap_or(default_value),
        Err(_) => default_value,
    }
}

async fn create_local_terminal_session(
    port: u16,
    cwd: &str,
    shell: &str,
    title: &str,
    cols: u16,
    rows: u16,
) -> anyhow::Result<CreateLocalTerminalSessionResponse> {
    let response = reqwest::Client::new()
        .post(local_http_url(port, "/terminals/sessions"))
        .json(&CreateLocalTerminalSessionRequest {
            cwd,
            shell,
            title,
            cols,
            rows,
        })
        .send()
        .await
        .context("failed to create local terminal session")?
        .error_for_status()
        .context("desktop-server rejected local terminal session request")?;
    response
        .json::<CreateLocalTerminalSessionResponse>()
        .await
        .context("failed to decode local terminal session response")
}

async fn close_local_terminal_session(port: u16, terminal_id: Uuid) -> anyhow::Result<()> {
    reqwest::Client::new()
        .post(local_http_url(
            port,
            format!("/terminals/sessions/{terminal_id}/close").as_str(),
        ))
        .send()
        .await
        .context("failed to request local terminal close")?
        .error_for_status()
        .context("desktop-server rejected local terminal close request")?;
    Ok(())
}

async fn attach_session(port: u16, terminal_id: &str) -> (bool, anyhow::Result<()>) {
    let url = local_ws_url(port, "/ws");
    let (socket, _) = match connect_async(url)
        .await
        .context("failed to connect local websocket")
    {
        Ok(value) => value,
        Err(error) => return (false, Err(error)),
    };
    let (mut write, mut read) = socket.split();

    if let Err(error) = write
        .send(Message::Text(
            serde_json::json!({
                "type": "terminal.attach",
                "payload": {
                    "terminal_id": terminal_id,
                    "protocol_version": RAW_STREAM_PROTOCOL_VERSION,
                    "sync_mode": RAW_STREAM_SYNC_MODE,
                    "client_kind": "system_terminal",
                }
            })
            .to_string()
            .into(),
        ))
        .await
        .context("failed to attach terminal session")
    {
        return (false, Err(error));
    }

    let mut stdout = io::stdout();
    let raw_mode_guard = match RawModeGuard::activate() {
        Ok(guard) => guard,
        Err(error) => return (false, Err(error)),
    };
    if let Err(error) = execute!(
        stdout,
        EnterAlternateScreen,
        Clear(ClearType::All),
        cursor::MoveTo(0, 0),
        cursor::Hide
    )
    .context("failed to prepare local terminal screen")
    {
        drop(raw_mode_guard);
        return (false, Err(error));
    }
    let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    spawn_stdin_reader(stdin_tx);

    let last_size = current_terminal_size(TerminalSize::new(120, 32));
    let mut viewer_presence_epoch: Option<u64> = None;
    let mut size_rx = spawn_terminal_size_watcher(last_size);
    let mut attached_once = false;
    let mut approval_prompt = CliApprovalPrompt::new(port, "sirix-terminal");

    let attach_result: anyhow::Result<TerminalDetachReason> = async {
        write_resize(&mut write, terminal_id, last_size, viewer_presence_epoch).await?;
        loop {
            tokio::select! {
                Some(bytes) = stdin_rx.recv() => {
                    if approval_prompt.has_pending() {
                        approval_prompt
                            .handle_stdin_bytes(&mut stdout, bytes.as_slice())
                            .await
                            .context("failed to handle approval input")?;
                        continue;
                    }
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
                Some(current_size) = size_rx.recv() => {
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
                message = read.next() => {
                    match message {
                        Some(Ok(Message::Text(text))) => {
                            if message_marks_terminal_ready(&text) {
                                attached_once = true;
                            }
                            if handle_terminal_message(
                                &mut stdout,
                                &text,
                                &mut viewer_presence_epoch,
                                &mut approval_prompt,
                            )? {
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
        }
    }.await;

    let detach_reason = match &attach_result {
        Ok(reason) => *reason,
        Err(_) => TerminalDetachReason::TransportClosed,
    };
    if attached_once {
        // 成功 attach 过之后，退出前显式发一次 detach，避免仅依赖 socket 关闭 +
        // server 侧延迟清理，缩短 authority 回收与后续 viewer 接管的收敛时间。
        let _ = write
            .send(Message::Text(
                serde_json::json!({
                    "type": "terminal.detach",
                    "payload": {
                        "terminal_id": terminal_id,
                        "client_kind": "system_terminal",
                        "viewer_presence_epoch": viewer_presence_epoch,
                    }
                })
                .to_string()
                .into(),
            ))
            .await;
    }
    drop(raw_mode_guard);
    let restore_result = restore_local_terminal(&mut stdout, detach_reason);
    let final_result = match attach_result {
        Ok(_) => restore_result.map_err(Into::into),
        Err(error) if is_graceful_terminal_disconnect(&error) => restore_result.map_err(Into::into),
        Err(error) => match restore_result {
            Ok(()) => Err(error),
            Err(restore_error) => Err(error.context(format!(
                "additionally failed to restore local terminal state: {restore_error}"
            ))),
        },
    };
    (attached_once, final_result)
}

async fn write_resize<S>(
    write: &mut S,
    terminal_id: &str,
    size: TerminalSize,
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
                "cols": size.cols,
                "rows": size.rows,
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
                .write_all(b"[sirix-terminal] shared terminal closed.\r\n")
                .context("failed to write session closed message")?;
        }
        TerminalDetachReason::TransportClosed => {
            stdout
                .write_all(
                    b"[sirix-terminal] desktop-server disconnected; shared terminal detached safely.\r\n",
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
    approval_prompt: &mut CliApprovalPrompt,
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
                eprintln!("\n[sirix-terminal] terminal error: {message}");
            }
            Ok(true)
        }
        "terminal.warning" => {
            if let Some(message) = decoded
                .get("payload")
                .and_then(|payload| payload.get("message"))
                .and_then(serde_json::Value::as_str)
            {
                eprintln!("\n\u{1b}[33m[sirix-terminal] {message}\u{1b}[0m");
            }
            if let Some(install_commands) = decoded
                .get("payload")
                .and_then(|payload| payload.get("install_commands"))
                .and_then(serde_json::Value::as_array)
            {
                for command in install_commands {
                    if let Some(command) = command.as_str() {
                        eprintln!("\u{1b}[33m  {command}\u{1b}[0m");
                    }
                }
            }
            Ok(false)
        }
        "terminal.closed" => Ok(true),
        "ai.approval.request" => {
            if let Some(body) = decoded.get("payload") {
                approval_prompt.handle_request_event(stdout, body)?;
            }
            Ok(false)
        }
        "ai.approval.resolved" => {
            if let Some(body) = decoded.get("payload") {
                approval_prompt.handle_resolved_event(stdout, body)?;
            }
            Ok(false)
        }
        _ => Ok(false),
    }
}

fn message_marks_terminal_ready(raw: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(raw)
        .ok()
        .and_then(|decoded| {
            decoded
                .get("type")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string)
        })
        .is_some_and(|event_type| event_type == "terminal.ready")
}

fn resolve_shared_shell() -> String {
    #[cfg(target_os = "windows")]
    {
        for candidate in ["pwsh", "powershell.exe", "cmd.exe"] {
            if executable_in_path(candidate) {
                return candidate.to_string();
            }
        }
        if let Ok(shell) = env::var("COMSPEC") {
            if !shell.trim().is_empty() {
                return shell;
            }
        }
        return "powershell.exe".to_string();
    }

    #[cfg(not(target_os = "windows"))]
    {
        if let Ok(shell) = env::var("SHELL") {
            if !shell.trim().is_empty() {
                return shell;
            }
        }
        #[cfg(target_os = "macos")]
        {
            return "/bin/zsh".to_string();
        }
        #[cfg(all(unix, not(target_os = "macos")))]
        {
            return "/bin/bash".to_string();
        }
    }
}

#[cfg(target_os = "windows")]
fn executable_in_path(name: &str) -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };
    env::split_paths(&path).any(|directory| directory.join(name).is_file())
}
