use crate::FreeformTool;
use crate::JsonSchema;
use crate::ResponsesApiTool;
use crate::create_apply_patch_json_tool;
use codex_protocol::config_types::WebSearchConfig;
use codex_protocol::config_types::WebSearchContextSize;
use codex_protocol::config_types::WebSearchFilters as ConfigWebSearchFilters;
use codex_protocol::config_types::WebSearchMode;
use codex_protocol::config_types::WebSearchUserLocation as ConfigWebSearchUserLocation;
use codex_protocol::config_types::WebSearchUserLocationType;
use codex_protocol::openai_models::WebSearchToolType;
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;

const WEB_SEARCH_TEXT_AND_IMAGE_CONTENT_TYPES: [&str; 2] = ["text", "image"];

/// When serialized as JSON, this produces a valid "Tool" in the OpenAI
/// Responses API.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum ToolSpec {
    #[serde(rename = "function")]
    Function(ResponsesApiTool),
    #[serde(rename = "tool_search")]
    ToolSearch {
        execution: String,
        description: String,
        parameters: JsonSchema,
    },
    #[serde(rename = "local_shell")]
    LocalShell {},
    #[serde(rename = "image_generation")]
    ImageGeneration { output_format: String },
    // TODO: Understand why we get an error on web_search although the API docs
    // say it's supported.
    // https://platform.openai.com/docs/guides/tools-web-search?api-mode=responses#:~:text=%7B%20type%3A%20%22web_search%22%20%7D%2C
    // The `external_web_access` field determines whether the web search is over
    // cached or live content.
    // https://platform.openai.com/docs/guides/tools-web-search#live-internet-access
    #[serde(rename = "web_search")]
    WebSearch {
        #[serde(skip_serializing_if = "Option::is_none")]
        external_web_access: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        filters: Option<ResponsesApiWebSearchFilters>,
        #[serde(skip_serializing_if = "Option::is_none")]
        user_location: Option<ResponsesApiWebSearchUserLocation>,
        #[serde(skip_serializing_if = "Option::is_none")]
        search_context_size: Option<WebSearchContextSize>,
        #[serde(skip_serializing_if = "Option::is_none")]
        search_content_types: Option<Vec<String>>,
    },
    #[serde(rename = "custom")]
    Freeform(FreeformTool),
}

impl ToolSpec {
    pub fn name(&self) -> &str {
        match self {
            ToolSpec::Function(tool) => tool.name.as_str(),
            ToolSpec::ToolSearch { .. } => "tool_search",
            ToolSpec::LocalShell {} => "local_shell",
            ToolSpec::ImageGeneration { .. } => "image_generation",
            ToolSpec::WebSearch { .. } => "web_search",
            ToolSpec::Freeform(tool) => tool.name.as_str(),
        }
    }
}

pub fn create_local_shell_tool() -> ToolSpec {
    ToolSpec::LocalShell {}
}

pub fn create_image_generation_tool(output_format: &str) -> ToolSpec {
    ToolSpec::ImageGeneration {
        output_format: output_format.to_string(),
    }
}

pub struct WebSearchToolOptions<'a> {
    pub web_search_mode: Option<WebSearchMode>,
    pub web_search_config: Option<&'a WebSearchConfig>,
    pub web_search_tool_type: WebSearchToolType,
}

pub fn create_web_search_tool(options: WebSearchToolOptions<'_>) -> Option<ToolSpec> {
    let external_web_access = match options.web_search_mode {
        Some(WebSearchMode::Cached) => Some(false),
        Some(WebSearchMode::Live) => Some(true),
        Some(WebSearchMode::Disabled) | None => None,
    }?;

    let search_content_types = match options.web_search_tool_type {
        WebSearchToolType::Text => None,
        WebSearchToolType::TextAndImage => Some(
            WEB_SEARCH_TEXT_AND_IMAGE_CONTENT_TYPES
                .into_iter()
                .map(str::to_string)
                .collect(),
        ),
    };

    Some(ToolSpec::WebSearch {
        external_web_access: Some(external_web_access),
        filters: options
            .web_search_config
            .and_then(|config| config.filters.clone().map(Into::into)),
        user_location: options
            .web_search_config
            .and_then(|config| config.user_location.clone().map(Into::into)),
        search_context_size: options
            .web_search_config
            .and_then(|config| config.search_context_size),
        search_content_types,
    })
}

#[derive(Debug, Clone, PartialEq)]
pub struct ConfiguredToolSpec {
    pub spec: ToolSpec,
    pub supports_parallel_tool_calls: bool,
}

impl ConfiguredToolSpec {
    pub fn new(spec: ToolSpec, supports_parallel_tool_calls: bool) -> Self {
        Self {
            spec,
            supports_parallel_tool_calls,
        }
    }

    pub fn name(&self) -> &str {
        self.spec.name()
    }
}

/// Returns JSON values that are compatible with Function Calling in the
/// Responses API:
/// https://platform.openai.com/docs/guides/function-calling?api-mode=responses
pub fn create_tools_json_for_responses_api(
    tools: &[ToolSpec],
) -> Result<Vec<Value>, serde_json::Error> {
    let mut tools_json = Vec::new();

    for tool in tools {
        let json = serde_json::to_value(tool)?;
        tools_json.push(json);
    }

    Ok(tools_json)
}

/// Returns JSON values that are compatible with function calling in the
/// Chat Completions API. This is intentionally a lossy normalization layer:
/// Responses-native built-ins such as `web_search` or `image_generation`
/// do not have a portable chat-completions equivalent, so only the subset
/// that Sirix can faithfully route through its existing local tool handlers
/// is exported here.
pub fn create_tools_json_for_chat_completions(
    tools: &[ToolSpec],
) -> Result<Vec<Value>, serde_json::Error> {
    let mut tools_json = Vec::new();

    for tool in tools {
        if let Some(json) = tool_spec_to_chat_completions_tool(tool)? {
            tools_json.push(json);
        }
    }

    Ok(tools_json)
}

fn tool_spec_to_chat_completions_tool(tool: &ToolSpec) -> Result<Option<Value>, serde_json::Error> {
    match tool {
        ToolSpec::Function(tool) => Ok(Some(function_tool_value(
            &tool.name,
            &tool.description,
            serde_json::to_value(&tool.parameters)?,
        ))),
        ToolSpec::ToolSearch {
            description,
            parameters,
            ..
        } => Ok(Some(function_tool_value(
            "tool_search",
            description,
            serde_json::to_value(parameters)?,
        ))),
        ToolSpec::Freeform(tool) => {
            if tool.name == "apply_patch" {
                let ToolSpec::Function(tool) = create_apply_patch_json_tool() else {
                    unreachable!("apply_patch json variant must remain a function tool");
                };
                return Ok(Some(function_tool_value(
                    &tool.name,
                    &tool.description,
                    serde_json::to_value(&tool.parameters)?,
                )));
            }

            // Chat-completions function calling cannot expose raw grammar-backed
            // payload channels. We preserve the tool name and description, and
            // wrap the freeform body into a single `input` string so the Sirix
            // runtime can keep handling the call with its native tool handlers.
            let description = format!(
                "{}\n\nFor chat-completions compatibility, send the raw tool payload in the `input` string field.",
                tool.description
            );
            Ok(Some(function_tool_value(
                &tool.name,
                &description,
                serde_json::to_value(freeform_tool_chat_parameters())?,
            )))
        }
        ToolSpec::LocalShell {} => Ok(Some(function_tool_value(
            "local_shell",
            "Runs a local shell command and returns its output.",
            serde_json::to_value(local_shell_chat_parameters())?,
        ))),
        ToolSpec::ImageGeneration { .. } | ToolSpec::WebSearch { .. } => Ok(None),
    }
}

fn function_tool_value(name: &str, description: &str, parameters: Value) -> Value {
    serde_json::json!({
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": parameters,
        }
    })
}

fn freeform_tool_chat_parameters() -> JsonSchema {
    JsonSchema::object(
        BTreeMap::from([(
            "input".to_string(),
            JsonSchema::string(Some(
                "The raw tool input body. Pass the exact freeform payload text without JSON wrappers inside this field.".to_string(),
            )),
        )]),
        Some(vec!["input".to_string()]),
        Some(false.into()),
    )
}

fn local_shell_chat_parameters() -> JsonSchema {
    JsonSchema::object(
        BTreeMap::from([
            (
                "command".to_string(),
                JsonSchema::array(
                    JsonSchema::string(None),
                    Some("The command to execute as argv segments.".to_string()),
                ),
            ),
            (
                "workdir".to_string(),
                JsonSchema::string(Some(
                    "Optional working directory to run the command in.".to_string(),
                )),
            ),
            (
                "timeout_ms".to_string(),
                JsonSchema::number(Some(
                    "Optional timeout in milliseconds.".to_string(),
                )),
            ),
        ]),
        Some(vec!["command".to_string()]),
        Some(false.into()),
    )
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ResponsesApiWebSearchFilters {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allowed_domains: Option<Vec<String>>,
}

impl From<ConfigWebSearchFilters> for ResponsesApiWebSearchFilters {
    fn from(filters: ConfigWebSearchFilters) -> Self {
        Self {
            allowed_domains: filters.allowed_domains,
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ResponsesApiWebSearchUserLocation {
    #[serde(rename = "type")]
    pub r#type: WebSearchUserLocationType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub country: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub city: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timezone: Option<String>,
}

impl From<ConfigWebSearchUserLocation> for ResponsesApiWebSearchUserLocation {
    fn from(user_location: ConfigWebSearchUserLocation) -> Self {
        Self {
            r#type: user_location.r#type,
            country: user_location.country,
            region: user_location.region,
            city: user_location.city,
            timezone: user_location.timezone,
        }
    }
}

#[cfg(test)]
#[path = "tool_spec_tests.rs"]
mod tests;
