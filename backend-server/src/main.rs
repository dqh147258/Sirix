mod api;
mod application;
mod bootstrap;
mod domain;

use std::net::SocketAddr;

use anyhow::Context;
use application::{
    runtime_logging::{RuntimeLogStore, RuntimeSettings, ENABLE_RUNTIME_LOGGING},
    state::AppState,
};
use axum::Router;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing::{error, info};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config = bootstrap::config::load_config().context("failed to load config")?;
    let runtime_logging_enabled = ENABLE_RUNTIME_LOGGING && config.runtime.logging_enabled;
    let runtime_settings = RuntimeSettings {
        logging_enabled: runtime_logging_enabled,
        max_lines_per_file: config.runtime.max_lines_per_file,
    };
    let log_store = std::sync::Arc::new(
        RuntimeLogStore::new(
            &config.runtime.logs_root_dir,
            config.runtime.max_run_directories,
            config.runtime.max_lines_per_file,
        )
        .context("failed to initialize runtime log store")?,
    );
    bootstrap::logging::init(
        &config.logging.level,
        config.logging.json,
        runtime_logging_enabled,
        Some(log_store.clone()),
    );

    let state = AppState::new(config.clone(), runtime_settings, log_store.clone())
        .await
        .context("failed to initialize application state")?;
    application::tasks::spawn_background_tasks(state.clone());

    let app = build_router(state.clone());

    let addr: SocketAddr = format!("{}:{}", config.server.host, config.server.port)
        .parse()
        .context("invalid server address")?;

    info!(
        address = %addr,
        runtime_log_dir = %log_store.run_dir().display(),
        logging_enabled = state.runtime_settings.logging_enabled,
        "backend-server starting"
    );

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
