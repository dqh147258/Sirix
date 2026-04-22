use std::collections::HashMap;
use std::collections::HashSet;
use std::env;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;

use crate::codex::Session;
use crate::codex::TurnContext;
use crate::config::Config;
use codex_analytics::InvocationType;
use codex_analytics::SkillInvocation;
use codex_analytics::build_track_events_context;
use codex_protocol::protocol::EventMsg;
use codex_protocol::protocol::SkillScope;
use codex_protocol::protocol::WarningEvent;
use codex_protocol::request_user_input::RequestUserInputArgs;
use codex_protocol::request_user_input::RequestUserInputQuestion;
use codex_protocol::request_user_input::RequestUserInputResponse;
use tracing::info;
use tracing::warn;

use crate::sirix_tool_approval::SirixToolApprovalDecision;
use crate::sirix_tool_approval::wait_for_sirix_tool_approval;

pub use codex_core_skills::SkillDependencyInfo;
pub use codex_core_skills::SkillError;
pub use codex_core_skills::SkillLoadOutcome;
pub use codex_core_skills::SkillMetadata;
pub use codex_core_skills::SkillPolicy;
pub use codex_core_skills::SkillsLoadInput;
pub use codex_core_skills::SkillsManager;
pub use codex_core_skills::build_skill_name_counts;
pub use codex_core_skills::collect_env_var_dependencies;
pub use codex_core_skills::config_rules;
pub use codex_core_skills::detect_implicit_skill_invocation_for_command;
pub use codex_core_skills::filter_skill_load_outcome_for_product;
pub use codex_core_skills::injection;
pub use codex_core_skills::injection::SkillInjections;
pub use codex_core_skills::injection::build_skill_injections;
pub use codex_core_skills::injection::collect_explicit_skill_mentions;
pub use codex_core_skills::loader;
pub use codex_core_skills::manager;
pub use codex_core_skills::model;
pub use codex_core_skills::remote;
pub use codex_core_skills::render;
pub use codex_core_skills::render_skills_section;
pub use codex_core_skills::system;

pub(crate) fn skills_load_input_from_config(
    config: &Config,
    effective_skill_roots: Vec<PathBuf>,
) -> SkillsLoadInput {
    SkillsLoadInput::new(
        config.cwd.clone().to_path_buf(),
        effective_skill_roots,
        config.config_layer_stack.clone(),
        config.bundled_skills_enabled(),
    )
}

pub(crate) async fn resolve_skill_dependencies_for_turn(
    sess: &Arc<Session>,
    turn_context: &Arc<TurnContext>,
    dependencies: &[SkillDependencyInfo],
) {
    if dependencies.is_empty() {
        return;
    }

    let existing_env = sess.dependency_env().await;
    let mut loaded_values = HashMap::new();
    let mut missing = Vec::new();
    let mut seen_names = HashSet::new();

    for dependency in dependencies {
        let name = dependency.name.clone();
        if !seen_names.insert(name.clone()) || existing_env.contains_key(&name) {
            continue;
        }
        match env::var(&name) {
            Ok(value) => {
                loaded_values.insert(name.clone(), value);
            }
            Err(env::VarError::NotPresent) => {
                missing.push(dependency.clone());
            }
            Err(err) => {
                warn!("failed to read env var {name}: {err}");
                missing.push(dependency.clone());
            }
        }
    }

    if !loaded_values.is_empty() {
        sess.set_dependency_env(loaded_values).await;
    }

    if !missing.is_empty() {
        request_skill_dependencies(sess, turn_context, &missing).await;
    }
}

pub(crate) async fn filter_skills_by_sirix_approval(
    sess: &Arc<Session>,
    turn_context: &Arc<TurnContext>,
    skills: Vec<SkillMetadata>,
) -> Vec<SkillMetadata> {
    let mut approved = Vec::with_capacity(skills.len());
    for skill in skills {
        let Some(capability_key) = sirix_skill_capability_key(&turn_context.config, &skill) else {
            approved.push(skill);
            continue;
        };
        match wait_for_sirix_tool_approval(
            capability_key.as_str(),
            turn_context.config.sirix_agent_id.as_deref(),
        )
        .await
        {
            Ok(Some(SirixToolApprovalDecision::Allow)) | Ok(None) => approved.push(skill),
            Ok(Some(SirixToolApprovalDecision::Deny)) => {
                let message = format!(
                    "skill `{}` was denied by the current Sirix approval policy",
                    skill.name
                );
                sess.send_event(turn_context, EventMsg::Warning(WarningEvent { message }))
                    .await;
            }
            Err(error) => {
                let message = format!("skill approval error for `{}`: {error}", skill.name);
                warn!("{message}");
                sess.send_event(turn_context, EventMsg::Warning(WarningEvent { message }))
                    .await;
            }
        }
    }
    approved
}

fn sirix_skill_capability_key(config: &Config, skill: &SkillMetadata) -> Option<String> {
    let configured_skill_dir = skill
        .path_to_skills_md
        .parent()?
        .to_string_lossy()
        .to_string();
    let effective_config = config.config_layer_stack.effective_config();
    let table = effective_config.as_table()?;
    let skills_table = table.get("skills")?.as_table()?;
    let config_entries = skills_table.get("config")?.as_array()?;
    for entry in config_entries {
        let entry_table = entry.as_table()?;
        let path = entry_table.get("path")?.as_str()?;
        if path != configured_skill_dir {
            continue;
        }
        let skill_id = entry_table
            .get("sirix_skill_id")
            .and_then(|value| value.as_str())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
            .unwrap_or_else(|| skill.name.trim().to_ascii_lowercase().replace(' ', "-"));
        info!(
            "resolved Sirix skill approval key for {} -> skill.{skill_id}",
            skill.name
        );
        return Some(format!("skill.{skill_id}"));
    }
    None
}

async fn request_skill_dependencies(
    sess: &Arc<Session>,
    turn_context: &Arc<TurnContext>,
    dependencies: &[SkillDependencyInfo],
) {
    let questions = dependencies
        .iter()
        .map(|dependency| {
            let requirement = dependency.description.as_ref().map_or_else(
                || {
                    format!(
                        "The skill \"{}\" requires \"{}\" to be set.",
                        dependency.skill_name, dependency.name
                    )
                },
                |description| {
                    format!(
                        "The skill \"{}\" requires \"{}\" to be set ({}).",
                        dependency.skill_name, dependency.name, description
                    )
                },
            );
            RequestUserInputQuestion {
                id: dependency.name.clone(),
                header: "Skill requires environment variable".to_string(),
                question: format!(
                    "{requirement} This is an experimental internal feature. The value is stored in memory for this session only."
                ),
                is_other: false,
                is_secret: true,
                options: None,
            }
        })
        .collect::<Vec<_>>();
    if questions.is_empty() {
        return;
    }

    let response = sess
        .request_user_input(
            turn_context,
            format!("skill-deps-{}", turn_context.sub_id),
            RequestUserInputArgs { questions },
        )
        .await
        .unwrap_or_else(|| RequestUserInputResponse {
            answers: HashMap::new(),
        });
    if response.answers.is_empty() {
        return;
    }

    let mut values = HashMap::new();
    for (name, answer) in response.answers {
        let mut user_note = None;
        for entry in &answer.answers {
            if let Some(note) = entry.strip_prefix("user_note: ")
                && !note.trim().is_empty()
            {
                user_note = Some(note.trim().to_string());
            }
        }
        if let Some(value) = user_note {
            values.insert(name, value);
        }
    }
    if values.is_empty() {
        return;
    }

    sess.set_dependency_env(values).await;
}

pub(crate) async fn maybe_emit_implicit_skill_invocation(
    sess: &Session,
    turn_context: &TurnContext,
    command: &str,
    workdir: &Path,
) {
    let Some(candidate) = detect_implicit_skill_invocation_for_command(
        turn_context.turn_skills.outcome.as_ref(),
        command,
        workdir,
    ) else {
        return;
    };
    let invocation = SkillInvocation {
        skill_name: candidate.name,
        skill_scope: candidate.scope,
        skill_path: candidate.path_to_skills_md,
        invocation_type: InvocationType::Implicit,
    };
    let skill_scope = match invocation.skill_scope {
        SkillScope::User => "user",
        SkillScope::Repo => "repo",
        SkillScope::System => "system",
        SkillScope::Admin => "admin",
    };
    let skill_path = invocation.skill_path.to_string_lossy();
    let skill_name = invocation.skill_name.clone();
    let seen_key = format!("{skill_scope}:{skill_path}:{skill_name}");
    let inserted = {
        let mut seen_skills = turn_context
            .turn_skills
            .implicit_invocation_seen_skills
            .lock()
            .await;
        seen_skills.insert(seen_key)
    };
    if !inserted {
        return;
    }

    turn_context.session_telemetry.counter(
        "codex.skill.injected",
        /*inc*/ 1,
        &[
            ("status", "ok"),
            ("skill", skill_name.as_str()),
            ("invoke_type", "implicit"),
        ],
    );
    sess.services
        .analytics_events_client
        .track_skill_invocations(
            build_track_events_context(
                turn_context.model_info.slug.clone(),
                sess.conversation_id.to_string(),
                turn_context.sub_id.clone(),
            ),
            vec![invocation],
        );
}
