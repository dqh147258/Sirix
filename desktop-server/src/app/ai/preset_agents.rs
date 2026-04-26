//! Built-in Sirix agent presets loaded from a JSON catalog.
//!
//! The JSON file is the source of truth used by both first-run config seeding
//! and the one-click import script. Keeping the catalog data outside Rust code
//! makes the prompts editable/reviewable without recompiling this module's
//! structure, while `include_str!` still keeps desktop-server startup
//! cross-platform and independent of runtime asset paths.

use std::sync::LazyLock;

use serde::Deserialize;

const PRESET_AGENT_CATALOG_JSON: &str = include_str!("../../../resources/preset_agents.json");

#[derive(Debug, Deserialize)]
pub struct PresetAgentCatalog {
    #[allow(dead_code)]
    pub version: u32,
    pub default_language: String,
    pub default_codex_sub_agent_ids: Vec<String>,
    pub agents: Vec<PresetAgentDefinition>,
}

#[derive(Debug, Deserialize)]
pub struct PresetAgentDefinition {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub provider_id: String,
    #[serde(default)]
    pub model_id: String,
    pub description: LocalizedText,
    pub system_prompt: LocalizedText,
    pub builtin_tool_ids: Vec<String>,
    #[serde(default = "default_true")]
    pub skills_enabled: bool,
    #[serde(default)]
    pub skill_ids: Vec<String>,
    #[serde(default = "default_true")]
    pub mcp_servers_enabled: bool,
    #[serde(default)]
    pub mcp_server_ids: Vec<String>,
    #[serde(default = "default_true")]
    pub sub_agents_enabled: bool,
    #[serde(default)]
    pub sub_agent_ids: Vec<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

#[derive(Debug, Deserialize)]
pub struct LocalizedText {
    pub en: String,
    pub zh: String,
}

impl LocalizedText {
    pub fn get(&self, language: &str) -> &str {
        match language {
            "zh" | "zh-cn" | "zh_cn" | "cn" => self.zh.as_str(),
            _ => self.en.as_str(),
        }
    }
}

impl PresetAgentDefinition {
    pub fn description_for(&self, language: &str) -> &str {
        self.description.get(language)
    }

    pub fn system_prompt_for(&self, language: &str) -> &str {
        self.system_prompt.get(language)
    }
}

pub static PRESET_AGENT_CATALOG: LazyLock<PresetAgentCatalog> = LazyLock::new(|| {
    serde_json::from_str(PRESET_AGENT_CATALOG_JSON)
        .expect("embedded preset agent catalog must be valid JSON")
});

pub fn preset_agents() -> &'static [PresetAgentDefinition] {
    PRESET_AGENT_CATALOG.agents.as_slice()
}

pub fn preset_default_language() -> &'static str {
    PRESET_AGENT_CATALOG.default_language.as_str()
}

pub fn default_codex_sub_agent_ids() -> Vec<String> {
    PRESET_AGENT_CATALOG.default_codex_sub_agent_ids.clone()
}

fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_catalog_has_bilingual_prompts() {
        let catalog = &*PRESET_AGENT_CATALOG;
        assert_eq!(catalog.default_language, "en");
        assert!(catalog.agents.iter().any(|agent| agent.id == "debugger"));
        for agent in &catalog.agents {
            assert!(
                !agent.description.en.trim().is_empty(),
                "{} missing en description",
                agent.id
            );
            assert!(
                !agent.description.zh.trim().is_empty(),
                "{} missing zh description",
                agent.id
            );
            assert!(
                !agent.system_prompt.en.trim().is_empty(),
                "{} missing en prompt",
                agent.id
            );
            assert!(
                !agent.system_prompt.zh.trim().is_empty(),
                "{} missing zh prompt",
                agent.id
            );
            assert!(
                agent.sub_agents_enabled || agent.sub_agent_ids.is_empty(),
                "{} lists sub-agents while delegation is disabled",
                agent.id
            );
        }
    }
}
