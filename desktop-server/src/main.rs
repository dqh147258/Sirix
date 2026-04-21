mod api;
mod app;
mod bootstrap;
mod scene;

use std::net::SocketAddr;

use anyhow::Context;
use app::{state::AppState, tasks::spawn_background_tasks};
use tower_http::cors::CorsLayer;
use tracing::{error, info};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config =
        bootstrap::config::load_config().context("failed to load desktop-server config")?;
    bootstrap::logging::init(&config.logging.level, config.logging.json);

    let (listener, bound_port) = bind_first_available(
        &config.local_ws.host,
        config.local_ws.port_range_start,
        config.local_ws.port_range_end,
    )
    .await
    .context("failed to bind local ws range")?;

    let state = AppState::new(config.clone(), bound_port);
    if let Ok(current_exe) = std::env::current_exe() {
        if let Err(error) = state
            .sirix_config_store
            .install_bin_shims(current_exe.as_path())
        {
            state.logger.warn(format!(
                "failed to install scene-aware Sirix bin shims: {error}"
            ));
        }
    }
    let app = api::router(state.clone()).layer(CorsLayer::permissive());

    install_panic_logger(state.clone());
    install_termination_logger(state.clone());
    state.logger.clone().spawn_flush_task();
    match state.auth_session_store.restore().await {
        Ok(Some(session)) => {
            state.logger.info(format!(
                "restored desktop auth session for user={}",
                session.username
            ));
        }
        Ok(None) => {
            state.logger.info("no persisted desktop auth session found");
        }
        Err(error) => {
            state
                .logger
                .warn(format!("failed to restore desktop auth session: {error}"));
        }
    }
    spawn_background_tasks(state.clone());

    info!(
        host = %config.local_ws.host,
        local_ws_port = bound_port,
        backend_base_url = %config.backend.base_url,
        "desktop-server started"
    );
    state.logger.info(format!(
        "desktop-server started host={} local_ws_port={} backend_base_url={}",
        config.local_ws.host, bound_port, config.backend.base_url
    ));

    if let Err(err) = axum::serve(listener, app).await {
        error!(error = %err, "desktop-server crashed");
        state.logger.error(format!("desktop-server crashed: {err}"));
        return Err(err.into());
    }

    info!("desktop-server serve loop exited");
    state
        .logger
        .warn("desktop-server serve loop exited without error".to_string());

    Ok(())
}

fn install_panic_logger(state: AppState) {
    let logger = state.logger.clone();
    std::panic::set_hook(Box::new(move |panic_info| {
        let payload = panic_info
            .payload()
            .downcast_ref::<&str>()
            .copied()
            .or_else(|| {
                panic_info
                    .payload()
                    .downcast_ref::<String>()
                    .map(String::as_str)
            })
            .unwrap_or("unknown panic payload");
        let location = panic_info
            .location()
            .map(|location| format!("{}:{}", location.file(), location.line()))
            .unwrap_or_else(|| "unknown".to_string());
        let message = format!("desktop-server panic payload={payload} location={location}");
        error!("{message}");
        logger.error(message);
    }));
}

#[cfg(unix)]
fn install_termination_logger(state: AppState) {
    tokio::spawn(async move {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
                info!("desktop-server received SIGTERM");
                state
                    .logger
                    .warn("desktop-server received SIGTERM".to_string());
            }
            Err(err) => {
                error!(error = %err, "failed to install SIGTERM handler");
                state
                    .logger
                    .warn(format!("failed to install SIGTERM handler: {err}"));
            }
        }
    });
}

#[cfg(not(unix))]
fn install_termination_logger(_state: AppState) {}

async fn bind_first_available(
    host: &str,
    start: u16,
    end: u16,
) -> anyhow::Result<(tokio::net::TcpListener, u16)> {
    for port in start..=end {
        let addr: SocketAddr = format!("{host}:{port}")
            .parse()
            .context("invalid socket address")?;
        if let Ok(listener) = tokio::net::TcpListener::bind(addr).await {
            return Ok((listener, port));
        }
    }

    anyhow::bail!("no port available in range {start}-{end}");
}
