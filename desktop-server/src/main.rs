mod api;
mod app;
mod bootstrap;

use std::net::SocketAddr;

use anyhow::Context;
use app::{state::AppState, tasks::spawn_background_tasks};
use tower_http::{cors::CorsLayer, trace::TraceLayer};
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
    let app = api::router(state.clone())
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive());

    spawn_background_tasks(state.clone());

    info!(
        host = %config.local_ws.host,
        local_ws_port = bound_port,
        backend_base_url = %config.backend.base_url,
        "desktop-server started"
    );

    if let Err(err) = axum::serve(listener, app).await {
        error!(error = %err, "desktop-server crashed");
        return Err(err.into());
    }

    Ok(())
}

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
