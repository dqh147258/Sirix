#[path = "../cli_support.rs"]
mod cli_support;
#[path = "../scene.rs"]
mod scene;

use std::{
    env,
    io::{self, Read, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use anyhow::Context;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use futures_util::{SinkExt, StreamExt};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use uuid::Uuid;

use cli_support::{
    ensure_desktop_server, ensure_login_prompt, local_http_url, local_ws_url, spawn_stdin_reader,
    RawModeGuard, CURRENT_TERMINAL_ENV, CURRENT_TERMINAL_KIND_ENV, TERMINAL_KIND_HOSTED_SHELL,
};
use scene::{resolve_scene, resolve_sirix_home, SIRIX_SCENE_ENV};

#[derive(Debug, serde::Serialize)]
struct CreateHostedTerminalSessionRequest<'a> {
    cwd: &'a str,
    shell: &'a str,
    title: &'a str,
    cols: u16,
    rows: u16,
}

#[derive(Debug, serde::Deserialize)]
struct CreateHostedTerminalSessionResponse {
    terminal_id: Uuid,
    host_token: String,
    mirrored_to_backend: bool,
}

#[derive(Debug, serde::Serialize)]
#[serde(tag = "type")]
enum HostedTerminalClientMessage<'a> {
    #[serde(rename = "terminal.host.register")]
    Register {
        terminal_id: Uuid,
        host_token: &'a str,
    },
    #[serde(rename = "terminal.host.output")]
    Output {
        terminal_id: Uuid,
        data_base64: String,
    },
    #[serde(rename = "terminal.host.resized")]
    Resized {
        terminal_id: Uuid,
        cols: u16,
        rows: u16,
    },
    #[serde(rename = "terminal.host.closed")]
    Closed { terminal_id: Uuid },
    #[serde(rename = "terminal.host.error")]
    Error {
        terminal_id: Uuid,
        error_message: String,
    },
}

#[derive(Debug, serde::Deserialize)]
#[serde(tag = "type")]
enum HostedTerminalServerMessage {
    #[serde(rename = "terminal.host.registered")]
    Registered {
        payload: HostedTerminalRegisteredPayload,
    },
    #[serde(rename = "terminal.host.input")]
    Input {
        terminal_id: Uuid,
        data_base64: String,
    },
    #[serde(rename = "terminal.host.resize")]
    Resize {
        terminal_id: Uuid,
        cols: u16,
        rows: u16,
    },
    #[serde(rename = "terminal.host.close")]
    Close { terminal_id: Uuid },
    #[serde(rename = "settings.sync")]
    SettingsSync,
    #[serde(rename = "pong")]
    Pong,
}

#[derive(Debug, serde::Deserialize)]
struct HostedTerminalRegisteredPayload {
    terminal_id: Uuid,
    ok: bool,
    error_message: Option<String>,
}

enum PtyEvent {
    Output(Vec<u8>),
    Closed,
    Error(String),
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

    let cwd = env::current_dir().context("failed to resolve current directory")?;
    let (cols, rows) = crossterm::terminal::size().unwrap_or((120, 32));
    let shell = resolve_shared_shell();
    let session = create_hosted_terminal_session(
        port,
        cwd.as_path(),
        shell.as_str(),
        "Sirix Terminal",
        cols,
        rows,
    )
    .await?;
    run_hosted_terminal(port, cwd, shell, session, cols, rows).await
}

async fn create_hosted_terminal_session(
    port: u16,
    cwd: &std::path::Path,
    shell: &str,
    title: &str,
    cols: u16,
    rows: u16,
) -> anyhow::Result<CreateHostedTerminalSessionResponse> {
    let cwd_string = cwd.display().to_string();
    let response = reqwest::Client::new()
        .post(local_http_url(port, "/terminals/hosted/sessions"))
        .json(&CreateHostedTerminalSessionRequest {
            cwd: &cwd_string,
            shell,
            title,
            cols,
            rows,
        })
        .send()
        .await
        .context("failed to create hosted terminal session")?
        .error_for_status()
        .context("desktop-server rejected hosted terminal session request")?;
    response
        .json::<CreateHostedTerminalSessionResponse>()
        .await
        .context("failed to decode hosted terminal session response")
}

async fn run_hosted_terminal(
    port: u16,
    cwd: PathBuf,
    shell: String,
    session: CreateHostedTerminalSessionResponse,
    cols: u16,
    rows: u16,
) -> anyhow::Result<()> {
    let (socket, _) = connect_async(local_ws_url(port, "/ws"))
        .await
        .context("failed to connect desktop-server local websocket")?;
    let (mut write, mut read) = socket.split();

    send_host_message(
        &mut write,
        &HostedTerminalClientMessage::Register {
            terminal_id: session.terminal_id,
            host_token: session.host_token.as_str(),
        },
    )
    .await?;
    wait_for_host_registration(&mut read, session.terminal_id).await?;

    let system = native_pty_system();
    let pair = system.openpty(PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    })?;

    let mut builder = CommandBuilder::new(shell.clone());
    builder.cwd(&cwd);
    apply_shared_shell_env(&mut builder, session.terminal_id)?;
    let child = Arc::new(Mutex::new(pair.slave.spawn_command(builder)?));
    let writer = Arc::new(Mutex::new(pair.master.take_writer()?));
    let master = Arc::new(Mutex::new(pair.master));
    let reader = master
        .lock()
        .map_err(|_| anyhow::anyhow!("terminal master poisoned"))?
        .try_clone_reader()?;

    let _raw_mode_guard = RawModeGuard::activate()?;
    let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    let (pty_tx, mut pty_rx) = tokio::sync::mpsc::unbounded_channel::<PtyEvent>();
    spawn_stdin_reader(stdin_tx);
    spawn_pty_reader(reader, pty_tx);

    let mut last_size = (cols, rows);
    let mut resize_tick = tokio::time::interval(Duration::from_millis(250));

    eprintln!(
        "[sirix-terminal] attached terminal_id={} mirrored_to_backend={}",
        session.terminal_id, session.mirrored_to_backend
    );

    loop {
        tokio::select! {
            Some(bytes) = stdin_rx.recv() => {
                let mut guard = writer
                    .lock()
                    .map_err(|_| anyhow::anyhow!("terminal writer poisoned"))?;
                guard.write_all(&bytes)?;
            }
            Some(event) = pty_rx.recv() => {
                match event {
                    PtyEvent::Output(bytes) => {
                        send_host_message(
                            &mut write,
                            &HostedTerminalClientMessage::Output {
                                terminal_id: session.terminal_id,
                                data_base64: BASE64.encode(bytes),
                            },
                        )
                        .await?;
                    }
                    PtyEvent::Closed => {
                        let _ = send_host_message(
                            &mut write,
                            &HostedTerminalClientMessage::Closed {
                                terminal_id: session.terminal_id,
                            },
                        )
                        .await;
                        break;
                    }
                    PtyEvent::Error(error_message) => {
                        let _ = send_host_message(
                            &mut write,
                            &HostedTerminalClientMessage::Error {
                                terminal_id: session.terminal_id,
                                error_message,
                            },
                        )
                        .await;
                        break;
                    }
                }
            }
            _ = resize_tick.tick() => {
                let current_size = crossterm::terminal::size().unwrap_or(last_size);
                if current_size != last_size {
                    last_size = current_size;
                    if let Ok(master) = master.lock() {
                        master.resize(PtySize {
                            rows: current_size.1,
                            cols: current_size.0,
                            pixel_width: 0,
                            pixel_height: 0,
                        })?;
                    }
                    send_host_message(
                        &mut write,
                        &HostedTerminalClientMessage::Resized {
                            terminal_id: session.terminal_id,
                            cols: current_size.0,
                            rows: current_size.1,
                        },
                    )
                    .await?;
                }
            }
            message = read.next() => {
                match message {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<HostedTerminalServerMessage>(&text) {
                            Ok(HostedTerminalServerMessage::Input { terminal_id, data_base64 }) if terminal_id == session.terminal_id => {
                                let bytes = BASE64.decode(data_base64)?;
                                let mut guard = writer
                                    .lock()
                                    .map_err(|_| anyhow::anyhow!("terminal writer poisoned"))?;
                                guard.write_all(&bytes)?;
                            }
                            Ok(HostedTerminalServerMessage::Resize { terminal_id, cols, rows }) if terminal_id == session.terminal_id => {
                                if let Ok(master) = master.lock() {
                                    master.resize(PtySize {
                                        rows,
                                        cols,
                                        pixel_width: 0,
                                        pixel_height: 0,
                                    })?;
                                }
                            }
                            Ok(HostedTerminalServerMessage::Close { terminal_id }) if terminal_id == session.terminal_id => {
                                kill_child(&child);
                                break;
                            }
                            Ok(HostedTerminalServerMessage::SettingsSync | HostedTerminalServerMessage::Pong | HostedTerminalServerMessage::Registered { .. }) => {}
                            Ok(_) => {}
                            Err(error) => {
                                eprintln!("[sirix-terminal] ignored invalid host ws payload: {error}");
                            }
                        }
                    }
                    Some(Ok(Message::Ping(data))) => {
                        write.send(Message::Pong(data)).await.ok();
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        kill_child(&child);
                        break;
                    }
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        kill_child(&child);
                        let error = anyhow::Error::new(error).context("host websocket read failed");
                        if is_graceful_host_disconnect(&error) {
                            eprintln!("[sirix-terminal] desktop-server disconnected; hosted shell detached safely.");
                            break;
                        }
                        return Err(error);
                    }
                }
            }
        }
    }

    kill_child(&child);
    let _ = write.send(Message::Close(None)).await;
    Ok(())
}

async fn wait_for_host_registration(
    read: &mut (impl futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
              + Unpin),
    terminal_id: Uuid,
) -> anyhow::Result<()> {
    while let Some(message) = read.next().await {
        match message {
            Ok(Message::Text(text)) => {
                match serde_json::from_str::<HostedTerminalServerMessage>(&text) {
                    Ok(HostedTerminalServerMessage::Registered { payload })
                        if payload.terminal_id == terminal_id =>
                    {
                        if payload.ok {
                            return Ok(());
                        }
                        anyhow::bail!(
                            "desktop-server rejected hosted terminal registration: {}",
                            payload
                                .error_message
                                .unwrap_or_else(|| "unknown error".to_string())
                        );
                    }
                    Ok(
                        HostedTerminalServerMessage::SettingsSync
                        | HostedTerminalServerMessage::Pong,
                    ) => {}
                    Ok(_) => {}
                    Err(error) => {
                        eprintln!("[sirix-terminal] ignored invalid pre-register payload: {error}");
                    }
                }
            }
            Ok(Message::Ping(_)) => {}
            Ok(Message::Close(_)) | Err(_) | Ok(_) => break,
        }
    }
    anyhow::bail!("desktop-server closed websocket before host registration completed")
}

async fn send_host_message(
    write: &mut (impl futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error>
              + Unpin),
    payload: &HostedTerminalClientMessage<'_>,
) -> anyhow::Result<()> {
    let encoded = serde_json::to_string(payload).context("failed to serialize host message")?;
    write
        .send(Message::Text(encoded.into()))
        .await
        .context("failed to send host websocket payload")
}

fn spawn_pty_reader(
    mut reader: Box<dyn Read + Send>,
    tx: tokio::sync::mpsc::UnboundedSender<PtyEvent>,
) {
    thread::spawn(move || {
        let mut stdout = io::stdout();
        let mut buffer = [0_u8; 4096];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => {
                    let _ = tx.send(PtyEvent::Closed);
                    break;
                }
                Ok(read_len) => {
                    let chunk = buffer[..read_len].to_vec();
                    if stdout.write_all(&chunk).is_err() {
                        let _ = tx.send(PtyEvent::Error(
                            "failed to write terminal output".to_string(),
                        ));
                        break;
                    }
                    stdout.flush().ok();
                    if tx.send(PtyEvent::Output(chunk)).is_err() {
                        break;
                    }
                }
                Err(error) => {
                    let _ = tx.send(PtyEvent::Error(error.to_string()));
                    break;
                }
            }
        }
    });
}

fn is_graceful_host_disconnect(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        let message = cause.to_string().to_ascii_lowercase();
        message.contains("connection reset without closing handshake")
            || message.contains("broken pipe")
            || message.contains("connection reset by peer")
            || message.contains("sending after closing")
    })
}

fn apply_shared_shell_env(builder: &mut CommandBuilder, terminal_id: Uuid) -> anyhow::Result<()> {
    let sirix_home = resolve_sirix_home().context("failed to resolve SIRIX_HOME")?;
    let bin_dir = sirix_home.join("bin");
    let path = env::var("PATH").unwrap_or_default();
    let separator = if cfg!(windows) { ';' } else { ':' };
    let augmented_path = if path.trim().is_empty() {
        bin_dir.display().to_string()
    } else {
        format!("{}{}{}", bin_dir.display(), separator, path)
    };

    // The shared shell inherits the same Sirix bin directory as desktop-owned
    // terminals, and it receives the terminal session id so nested
    // `sirix-terminal` launches can be rejected deterministically.
    builder.env("PATH", augmented_path);
    builder.env("SIRIX_HOME", sirix_home);
    builder.env(SIRIX_SCENE_ENV, resolve_scene()?.as_str());
    builder.env(CURRENT_TERMINAL_ENV, terminal_id.to_string());
    builder.env(CURRENT_TERMINAL_KIND_ENV, TERMINAL_KIND_HOSTED_SHELL);
    Ok(())
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

fn kill_child(child: &Arc<Mutex<Box<dyn portable_pty::Child + Send + Sync>>>) {
    if let Ok(mut child) = child.lock() {
        let _ = child.kill();
        let _ = child.wait();
    }
}
