mod api;
mod application;
mod bootstrap;
mod domain;

use std::net::SocketAddr;

use anyhow::Context;
use application::state::AppState;
use axum::Router;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing::{error, info};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config = bootstrap::config::load_config().context("failed to load config")?;
    bootstrap::logging::init(&config.logging.level, config.logging.json);

    let state = AppState::new(config.clone())
        .await
        .context("failed to initialize application state")?;
    let app = build_router(state);

    let addr: SocketAddr = format!("{}:{}", config.server.host, config.server.port)
        .parse()
        .context("invalid server address")?;

    info!(address = %addr, "backend-server starting");

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .context("failed to bind listener")?;

    if let Err(err) = axum::serve(listener, app).await {
        error!(error = %err, "server exited unexpectedly");
        return Err(err.into());
    }

    Ok(())
}

fn build_router(state: AppState) -> Router {
    api::router(state)
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
}
