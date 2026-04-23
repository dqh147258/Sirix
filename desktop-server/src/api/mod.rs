use axum::{routing::get, Router};

use crate::app::state::AppState;

pub mod ai;
pub mod auth;
pub mod health;
pub mod settings;
pub mod status;
pub mod terminals;
pub mod ws;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health::health))
        .route("/status/overview", get(status::get_status_overview))
        .route(
            "/auth/session",
            get(auth::get_session)
                .post(auth::login)
                .delete(auth::logout),
        )
        .route("/auth/register", axum::routing::post(auth::register))
        .route(
            "/settings",
            get(settings::get_settings).patch(settings::set_settings),
        )
        .route(
            "/terminals/sessions",
            axum::routing::post(terminals::create_local_terminal_session),
        )
        .route(
            "/terminals/sessions/:terminal_id/close",
            axum::routing::post(terminals::close_local_terminal_session),
        )
        .route(
            "/ai/config",
            get(ai::get_ai_config).patch(ai::set_ai_config),
        )
        .route("/ai/workspaces/recent", get(ai::get_recent_workspaces))
        .route(
            "/ai/workspaces/select",
            axum::routing::post(ai::select_workspace),
        )
        .route(
            "/ai/workspaces/settings",
            get(ai::get_workspace_settings).patch(ai::save_workspace_settings),
        )
        .route(
            "/ai/workspace-settings",
            get(ai::get_workspace_settings).patch(ai::save_workspace_settings),
        )
        .route(
            "/ai/config/system-prompt-preview",
            axum::routing::post(ai::preview_agent_system_prompt),
        )
        .route(
            "/ai/shell-rules",
            get(ai::get_shell_rules).patch(ai::set_shell_rules),
        )
        .route(
            "/ai/tool-rules",
            get(ai::get_tool_rules).patch(ai::set_tool_rules),
        )
        .route("/ai/config/effective", get(ai::get_effective_ai_config))
        .route(
            "/ai/providers/models",
            axum::routing::post(ai::discover_provider_models),
        )
        .route(
            "/ai/providers/:provider_id/openai-auth/status",
            get(ai::get_openai_auth_status),
        )
        .route(
            "/ai/providers/:provider_id/openai-auth/login",
            axum::routing::post(ai::start_openai_auth_login),
        )
        .route(
            "/ai/providers/:provider_id/openai-auth/logout",
            axum::routing::post(ai::logout_openai_auth),
        )
        .route(
            "/ai/providers/:provider_id/openai-auth/import",
            axum::routing::post(ai::import_openai_auth_json),
        )
        .route(
            "/ai/sessions",
            get(ai::list_sessions).post(ai::launch_session),
        )
        .route("/ai/sessions/resolve", get(ai::resolve_session))
        .route(
            "/ai/sessions/:ai_session_id/agents",
            get(ai::list_session_agents),
        )
        .route(
            "/ai/sessions/:ai_session_id/agent",
            axum::routing::post(ai::switch_session_agent),
        )
        .route(
            "/ai/sessions/:ai_session_id/shell-rules/resolve",
            axum::routing::post(ai::resolve_session_shell_rule),
        )
        .route(
            "/ai/sessions/:ai_session_id/shell-approvals/request",
            axum::routing::post(ai::create_session_shell_approval_request),
        )
        .route(
            "/ai/sessions/:ai_session_id/shell-approvals/check",
            axum::routing::post(ai::check_session_shell_approval),
        )
        .route(
            "/ai/sessions/:ai_session_id/shell-approvals/resolve",
            axum::routing::post(ai::resolve_session_shell_approval),
        )
        .route(
            "/ai/sessions/approvals/check",
            axum::routing::post(ai::check_approval),
        )
        .route(
            "/ai/sessions/approvals/resolve",
            axum::routing::post(ai::resolve_approval),
        )
        .route(
            "/ai/sessions/:ai_session_id/provider/v1/responses",
            axum::routing::post(ai::proxy_compatible_responses),
        )
        .route(
            "/ai/sessions/:ai_session_id/provider/v1/models",
            get(ai::proxy_compatible_models),
        )
        .route("/ws", get(ws::local_ws_upgrade))
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::router;
    use crate::{
        app::state::AppState,
        bootstrap::config::{
            AppConfig, AuthorizationConfig, BackendConfig, CaptureConfig, LocalWsConfig,
            LoggingConfig, StreamConfig,
        },
    };

    fn test_state() -> AppState {
        AppState::new(
            AppConfig {
                backend: BackendConfig {
                    base_url: "http://127.0.0.1:3000".to_string(),
                    health_path: "/health".to_string(),
                    heartbeat_path: "/heartbeat".to_string(),
                    heartbeat_interval_seconds: 30,
                    device_id: uuid::Uuid::new_v4().to_string(),
                    event_ws_path: "/events".to_string(),
                    session_decision_path: "/session-decision".to_string(),
                    webrtc_signal_path: "/webrtc".to_string(),
                    runtime_settings_path: "/runtime-settings".to_string(),
                    runtime_logs_path: "/runtime-logs".to_string(),
                    pending_sessions_path: "/pending-sessions".to_string(),
                    screen_state_path: "/screen-state".to_string(),
                },
                local_ws: LocalWsConfig {
                    host: "127.0.0.1".to_string(),
                    port_range_start: 18080,
                    port_range_end: 18090,
                },
                authorization: AuthorizationConfig::default(),
                capture: CaptureConfig {
                    snapshot_interval_seconds: 5,
                    snapshot_width: 1280,
                },
                stream: StreamConfig {
                    default_profile: "balanced".to_string(),
                    default_fps: 15,
                    auto_adapt: true,
                },
                logging: LoggingConfig {
                    level: "info".to_string(),
                    json: false,
                },
            },
            18080,
        )
    }

    #[test]
    fn router_builds_with_workspace_routes_once() {
        let result = std::panic::catch_unwind(|| {
            let _ = router(test_state());
        });
        assert!(
            result.is_ok(),
            "router should build without overlapping workspace route panics"
        );
    }
}
