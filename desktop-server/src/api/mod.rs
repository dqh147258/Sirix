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
            "/terminals/hosted/sessions",
            axum::routing::post(terminals::create_hosted_terminal_session),
        )
        .route(
            "/ai/config",
            get(ai::get_ai_config).patch(ai::set_ai_config),
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
