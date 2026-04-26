#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/import-preset-agents.sh [options]

Import Sirix preset Agent profiles from desktop-server/resources/preset_agents.json.

Options:
  --language en|zh       Prompt language to import. Default: en.
  --sirix-home PATH      Sirix home directory. Default: $SIRIX_HOME or ~/.sirix.
  --config PATH          Direct config.toml path. Overrides --sirix-home.
  --provider-id ID       Optional provider id to pin newly imported preset agents.
  --model-id ID          Optional model id to pin newly imported preset agents.
  --no-update-codex      Do not merge preset sub-agent ids into the codex agent.
  --override             Overwrite existing same-id preset Agent files.
  -h, --help             Show this help.

The script creates a timestamped .bak backup when config.toml already exists.
Preset Agent files are written to SIRIX_HOME/agents/*.toml. Existing same-id
Agent files are refreshed from the catalog by default while preserving only
user model and permission/capability fields; pass --override to replace those
fields with catalog defaults too.
USAGE
}

LANGUAGE="en"
SIRIX_HOME_DIR="${SIRIX_HOME:-$HOME/.sirix}"
CONFIG_PATH=""
PROVIDER_ID=""
MODEL_ID=""
UPDATE_CODEX="1"
OVERRIDE_AGENTS="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --language)
      LANGUAGE="${2:-}"; shift 2 ;;
    --sirix-home)
      SIRIX_HOME_DIR="${2:-}"; shift 2 ;;
    --config)
      CONFIG_PATH="${2:-}"; shift 2 ;;
    --provider-id)
      PROVIDER_ID="${2:-}"; shift 2 ;;
    --model-id)
      MODEL_ID="${2:-}"; shift 2 ;;
    --no-update-codex)
      UPDATE_CODEX="0"; shift ;;
    --override)
      OVERRIDE_AGENTS="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ "$LANGUAGE" != "en" && "$LANGUAGE" != "zh" ]]; then
  echo "--language must be 'en' or 'zh'" >&2
  exit 2
fi

if [[ -z "$CONFIG_PATH" ]]; then
  CONFIG_PATH="$SIRIX_HOME_DIR/config.toml"
fi

CATALOG_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/desktop-server/resources/preset_agents.json"

python3 - "$CATALOG_PATH" "$CONFIG_PATH" "$LANGUAGE" "$PROVIDER_ID" "$MODEL_ID" "$UPDATE_CODEX" "$OVERRIDE_AGENTS" <<'PY'
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path
try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None

catalog_path = Path(sys.argv[1])
config_path = Path(sys.argv[2]).expanduser()
language = sys.argv[3]
provider_arg = sys.argv[4].strip()
model_arg = sys.argv[5].strip()
update_codex = sys.argv[6] == "1"
override_agents = sys.argv[7] == "1"

catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
preset_ids = {agent["id"] for agent in catalog["agents"]}
default_sub_agents = catalog.get("default_codex_sub_agent_ids", [])


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def toml_string_array(values) -> str:
    return "[" + ", ".join(toml_string(str(value)) for value in values) + "]"


def toml_key(key: str) -> str:
    return key if re.match(r'^[A-Za-z0-9_-]+$', key) else toml_string(key)


def first_match(pattern: str, text: str) -> str:
    match = re.search(pattern, text, flags=re.MULTILINE | re.DOTALL)
    return match.group(1).strip() if match else ""


def infer_provider_and_model(text: str):
    provider = provider_arg or first_match(r'^\s*id\s*=\s*"([^"]+)"\s*$', first_table(text, "providers")) or "openai"
    model = model_arg or first_match(r'^\s*id\s*=\s*"([^"]+)"\s*$', first_table(text, r"providers\.models")) or "gpt-5"
    return provider, model


def first_table(text: str, table_name: str) -> str:
    pattern = re.compile(rf'^\[\[{table_name}\]\]\s*$.*?(?=^\[\[|\Z)', re.MULTILINE | re.DOTALL)
    match = pattern.search(text)
    return match.group(0) if match else ""


def agent_id(block: str) -> str:
    return first_match(r'^\s*id\s*=\s*"([^"]+)"\s*$', block)


def parse_toml_header(line: str):
    stripped = line.strip()
    match = re.match(r'^\[\[([^\]]+)\]\]\s*(?:#.*)?$', stripped)
    if match:
        return match.group(1).strip(), True
    match = re.match(r'^\[([^\]]+)\]\s*(?:#.*)?$', stripped)
    if match:
        return match.group(1).strip(), False
    return None


def split_config_and_inline_agent_blocks(text: str):
    """Extract legacy inline `[[agents]]` blocks without leaving child tables.

    Inline Agent blocks may contain nested TOML tables like
    `[agents.builtin_approvals]` and `[[agents.builtin_approvals.rules]]`.
    A regex that stops at the next `[[...]]` leaves those child tables orphaned
    in `config.toml`, which makes top-level `agents` deserialize as a map
    instead of `Vec<AgentConfig>`.  This scanner keeps child tables attached to
    the current inline Agent and also drops orphaned `agents.*` fragments left
    by older broken imports.
    """
    parts = []
    blocks = []
    current = None
    skipping_orphan_agent_child = False

    def process_outside(line: str, header):
        nonlocal current, skipping_orphan_agent_child
        if header:
            name, is_array = header
            if is_array and name == "agents":
                current = [line]
                return
            if name.startswith("agents."):
                skipping_orphan_agent_child = True
                return
        parts.append(line)

    for line in text.splitlines(keepends=True):
        header = parse_toml_header(line)
        if current is not None:
            if header:
                name, is_array = header
                if is_array and name == "agents":
                    blocks.append("".join(current))
                    current = [line]
                    continue
                if name.startswith("agents."):
                    current.append(line)
                    continue
                blocks.append("".join(current))
                current = None
                process_outside(line, header)
                continue
            current.append(line)
            continue

        if skipping_orphan_agent_child:
            if not header:
                continue
            name, _is_array = header
            if name.startswith("agents."):
                continue
            skipping_orphan_agent_child = False
            process_outside(line, header)
            continue

        process_outside(line, header)

    if current is not None:
        blocks.append("".join(current))
    return "".join(parts), blocks


def render_default_provider(provider_id: str, model_id: str) -> str:
    return f'''version = 1
default_agent_id = "codex"

[[providers]]
id = {toml_string(provider_id)}
name = "OpenAI"
kind = "open_ai_responses"
default_context_window = 200000
base_url = "https://api.openai.com/v1"
api_key_env = "OPENAI_API_KEY"
api_key = ""
headers_json = "{{}}"
enabled = true

[[providers.models]]
id = {toml_string(model_id)}
display_name = "GPT-5"
model_kind = "text"
supports_images = true
enabled = true
'''


def render_agent_block(agent: dict, provider_id: str, model_id: str) -> str:
    desc = agent.get("description", {}).get(language) or agent.get("description", {}).get("en", "")
    prompt = agent.get("system_prompt", {}).get(language) or agent.get("system_prompt", {}).get("en", "")
    agent_provider_id = provider_arg or str(agent.get("provider_id", "")).strip()
    agent_model_id = model_arg or str(agent.get("model_id", "")).strip()
    return f'''
[[agents]]
id = {toml_string(agent["id"])}
name = {toml_string(agent["name"])}
description = {toml_string(desc)}
provider_id = {toml_string(agent_provider_id)}
model_id = {toml_string(agent_model_id)}
fallback_provider_id = ""
fallback_model_id = ""
system_prompt = {toml_string(prompt)}
approval_mode = "ask"
builtin_tool_ids = {toml_string_array(agent.get("builtin_tool_ids", []))}
skills_enabled = {str(bool(agent.get("skills_enabled", True))).lower()}
skill_ids = {toml_string_array(agent.get("skill_ids", []))}
mcp_servers_enabled = {str(bool(agent.get("mcp_servers_enabled", True))).lower()}
mcp_server_ids = {toml_string_array(agent.get("mcp_server_ids", []))}
sub_agents_enabled = {str(bool(agent.get("sub_agents_enabled", True))).lower()}
sub_agent_ids = {toml_string_array(agent.get("sub_agent_ids", []))}
enabled = {str(bool(agent.get("enabled", True))).lower()}
'''


def render_agent_file(agent: dict, provider_id: str, model_id: str) -> str:
    block = render_agent_block(agent, provider_id, model_id).strip()
    return re.sub(r'^\[\[agents\]\]\n', "", block, count=1)


def render_codex_block(provider_id: str, model_id: str) -> str:
    return f'''
[[agents]]
id = "codex"
name = "Codex"
description = "Built-in Codex agent with the standard Codex system prompt."
provider_id = {toml_string(provider_id)}
model_id = {toml_string(model_id)}
fallback_provider_id = ""
fallback_model_id = ""
system_prompt = ""
approval_mode = "ask"
builtin_tool_ids = {toml_string_array(["shell", "shell_command", "exec_command", "write_stdin", "apply_patch", "update_plan", "request_user_input", "request_permissions", "view_image", "web_search", "image_generation", "code_mode", "js_repl", "js_repl_reset", "list_dir", "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource", "spawn_agent", "send_message", "followup_task", "wait_agent", "close_agent", "list_agents"])}
skills_enabled = true
skill_ids = []
mcp_servers_enabled = true
mcp_server_ids = []
sub_agents_enabled = true
sub_agent_ids = {toml_string_array(default_sub_agents if update_codex else [])}
enabled = true
'''


def render_codex_file(provider_id: str, model_id: str) -> str:
    block = render_codex_block(provider_id, model_id).strip()
    return re.sub(r'^\[\[agents\]\]\n', "", block, count=1)


def agent_file_body_from_block(block: str) -> str:
    body = re.sub(r'^\[\[agents\]\]\n', "", block.strip(), count=1)
    # When migrating one inline Agent into agents/*.toml, remove the enclosing
    # `agents.` prefix from child tables that originally belonged to the latest
    # `[[agents]]` array item.
    body = re.sub(r'(?m)^\[agents\.', "[", body)
    body = re.sub(r'(?m)^\[\[agents\.', "[[", body)
    return body


PRESERVED_AGENT_KEYS = [
    # Model routing choices are user-specific and should survive catalog refreshes.
    "provider_id",
    "model_id",
    "model_reasoning_effort",
    "fallback_provider_id",
    "fallback_model_id",
    # Permission/capability choices are also user-specific.  Keep these while
    # refreshing descriptive and prompt fields from the latest preset catalog.
    "approval_mode",
    "shell_rules",
    "tool_rules",
    "builtin_approvals",
    "skill_approvals",
    "mcp_approvals",
    "builtin_tool_ids",
    "skills_enabled",
    "skill_ids",
    "mcp_servers_enabled",
    "mcp_server_ids",
    "sub_agents_enabled",
    "sub_agent_ids",
    "enabled",
    # Legacy permission fields may still exist in hand-edited or migrated files.
    "builtin_tools_enabled",
    "enabled_skill_ids",
    "disabled_skill_ids",
    "enabled_mcp_server_ids",
    "disabled_mcp_server_ids",
    "capability_rules",
]

AGENT_KEY_ORDER = [
    "id",
    "name",
    "description",
    "provider_id",
    "model_id",
    "model_reasoning_effort",
    "fallback_provider_id",
    "fallback_model_id",
    "system_prompt",
    "approval_mode",
    "builtin_tool_ids",
    "skills_enabled",
    "skill_ids",
    "mcp_servers_enabled",
    "mcp_server_ids",
    "sub_agents_enabled",
    "sub_agent_ids",
    "enabled",
    "builtin_tools_enabled",
    "enabled_skill_ids",
    "disabled_skill_ids",
    "enabled_mcp_server_ids",
    "disabled_mcp_server_ids",
    "capability_rules",
    "shell_rules",
    "tool_rules",
    "builtin_approvals",
    "skill_approvals",
    "mcp_approvals",
]


def ordered_keys(mapping: dict, preferred_order=None):
    preferred_order = preferred_order or []
    seen = set()
    for key in preferred_order:
        if key in mapping:
            seen.add(key)
            yield key
    for key in sorted(mapping):
        if key not in seen:
            yield key


def render_toml_value(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return toml_string(value)
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, list):
        return "[" + ", ".join(render_toml_value(item) for item in value) + "]"
    raise TypeError(f"unsupported TOML value type: {type(value).__name__}")


def render_toml_table(table: dict, prefix=None, key_order=None):
    prefix = prefix or []
    key_order = key_order if prefix == [] else None
    lines = []
    nested_tables = []
    array_tables = []
    for key in ordered_keys(table, key_order):
        value = table[key]
        if value is None:
            continue
        if isinstance(value, dict):
            nested_tables.append((key, value))
        elif isinstance(value, list) and any(isinstance(item, dict) for item in value):
            array_tables.append((key, value))
        else:
            lines.append(f"{toml_key(key)} = {render_toml_value(value)}")

    for key, value in nested_tables:
        table_path = [*prefix, key]
        if lines and lines[-1] != "":
            lines.append("")
        lines.append("[" + ".".join(toml_key(part) for part in table_path) + "]")
        lines.extend(render_toml_table(value, table_path))

    for key, values in array_tables:
        table_path = [*prefix, key]
        for item in values:
            if not isinstance(item, dict):
                continue
            if lines and lines[-1] != "":
                lines.append("")
            lines.append("[[" + ".".join(toml_key(part) for part in table_path) + "]]")
            lines.extend(render_toml_table(item, table_path))

    return lines


def parse_agent_body(body: str):
    if tomllib is None:
        return None
    try:
        parsed = tomllib.loads(body)
    except Exception:
        return None
    agents = parsed.get("agents")
    if isinstance(agents, list) and agents and isinstance(agents[0], dict):
        return agents[0]
    return parsed if isinstance(parsed, dict) else None


def dump_agent_body(agent: dict) -> str:
    return "\n".join(render_toml_table(agent, key_order=AGENT_KEY_ORDER)).rstrip()


def merge_agent_model_and_permissions(default_body: str, existing_body: str, aid: str) -> str:
    default_agent = parse_agent_body(default_body)
    existing_agent = parse_agent_body(existing_body)
    if default_agent is None or existing_agent is None:
        print(
            f"Warning: could not parse existing/default Agent {aid}; using preset defaults",
            file=sys.stderr,
        )
        return default_body
    for key in PRESERVED_AGENT_KEYS:
        if key in existing_agent:
            default_agent[key] = existing_agent[key]
    if aid == "codex" and update_codex:
        merged = []
        for value in [*default_agent.get("sub_agent_ids", []), *default_sub_agents]:
            if value and value not in merged:
                merged.append(value)
        default_agent["sub_agent_ids"] = merged
    return dump_agent_body(default_agent)


def safe_file_stem(agent_id: str) -> str:
    value = []
    for byte in agent_id.encode("utf-8"):
        char = chr(byte)
        if char.isascii() and (char.isalnum() or char in "_-"):
            value.append(char)
        else:
            value.append(f"~{byte:02x}")
    stem = "".join(value) or "agent"
    if stem.upper() in {"CON", "PRN", "AUX", "NUL"}:
        stem += "~"
    return stem


def render_agent_doc(agent: dict) -> str:
    desc = agent.get("description", {}).get(language) or agent.get("description", {}).get("en", "")
    prompt = agent.get("system_prompt", {}).get(language) or agent.get("system_prompt", {}).get("en", "")
    sub_agents = agent.get("sub_agent_ids", [])
    sub_agent_text = ", ".join(f"`{item}`" for item in sub_agents) if sub_agents else "None"
    tools = agent.get("builtin_tool_ids", [])
    tool_text = ", ".join(f"`{item}`" for item in tools) if tools else "None"
    return f"""# {agent["name"]}

## When To Use

{desc}

## Delegation

- Can spawn sub-agents: `{str(bool(agent.get("sub_agents_enabled", True))).lower()}`
- Preferred sub-agents: {sub_agent_text}

## Builtin Tools

{tool_text}

## Agent Instructions

{prompt}
"""


def skill_frontmatter(name: str, description: str) -> str:
    # Codex's native skill loader requires YAML frontmatter.  json.dumps emits
    # YAML-compatible double-quoted scalars, which keeps translated descriptions
    # and punctuation parseable without introducing a PyYAML dependency.
    return (
        "---\n"
        f"name: {toml_string(name)}\n"
        f"description: {toml_string(description)}\n"
        "---\n\n"
    )


def render_agent_skill(agent: dict) -> str:
    desc = agent.get("description", {}).get(language) or agent.get("description", {}).get("en", "")
    return f"""{skill_frontmatter(agent["id"], desc)}# {agent["name"]}

Use this skill when the user invokes `${agent["id"]}` or when the task should run through the Sirix preset Agent `{agent["id"]}`.

## Activation

- Treat this skill as an explicit request to use Agent `{agent["id"]}`.
- If Sirix Agent switching is available, switch/select `agent_id = "{agent["id"]}"` before continuing.
- If working inside a parent Agent, delegate with `spawn_agent` / Sirix sub-agent routing to `{agent["id"]}` when delegation is safer than continuing inline.
- If neither switching nor delegation is available, follow this Agent's instructions inline and state that Agent switching was unavailable.

{render_agent_doc(agent)}
"""


def write_preset_skill(sirix_home: Path):
    skills_home = sirix_home / "skills"
    skill_dir = sirix_home / "skills" / "sirix-preset-agents"
    docs_dir = skill_dir / "agents"
    docs_dir.mkdir(parents=True, exist_ok=True)
    lines = [
        skill_frontmatter(
            "sirix-preset-agents",
            "Choose or dispatch Sirix preset Agents for planning, implementation, review, and debugging workflows.",
        ).rstrip(),
        "# Sirix Preset Agent Routing",
        "",
        "Use this skill when choosing or dispatching Sirix preset Agents.",
        "",
        "## Routing Rules",
        "",
        "- Prefer `orchestrator` for broad tasks that need staged planning, execution, and verification.",
        "- Prefer planner Agents for product or implementation planning before code changes.",
        "- Prefer coordinator Agents for bug-fix and code-review workflows that need multiple specialist passes.",
        "- Prefer focused specialist Agents when the task maps directly to one role.",
        "- Check the per-Agent docs in `agents/` before delegating when role boundaries are unclear.",
        "",
        "## Preset Agents",
        "",
    ]
    for agent in catalog["agents"]:
        file_name = safe_file_stem(agent["id"]) + ".md"
        (docs_dir / file_name).write_text(render_agent_doc(agent), encoding="utf-8")
        agent_skill_dir = skills_home / safe_file_stem(agent["id"])
        agent_skill_dir.mkdir(parents=True, exist_ok=True)
        (agent_skill_dir / "SKILL.md").write_text(render_agent_skill(agent), encoding="utf-8")
        desc = agent.get("description", {}).get(language) or agent.get("description", {}).get("en", "")
        lines.append(f"- `{agent['id']}` — {desc} See `agents/{file_name}`.")
    (skill_dir / "SKILL.md").write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def render_skill_block(skill_id: str, name: str, path: Path) -> str:
    return f'''
[[skills]]
id = {toml_string(skill_id)}
name = {toml_string(name)}
path = {toml_string(str(path))}
enabled = true
allow_outside_sandbox = false
'''


def remove_empty_root_array_key(text: str, key: str) -> str:
    """Remove a top-level `key = []` line before appending `[[key]]`.

    SirixConfig serializes empty Vec fields as `skills = []`.  TOML treats that
    scalar array as defining the immutable top-level `skills` key, so a later
    `[[skills]]` array-of-tables fails to parse with "duplicate key" /
    "Cannot mutate immutable namespace".  Only the root preamble before the
    first table header is touched here so similarly named keys inside provider,
    agent, or approval tables cannot be removed by accident.
    """
    lines = text.splitlines(keepends=True)
    first_table_index = next(
        (index for index, line in enumerate(lines) if re.match(r'^\s*\[', line)),
        len(lines),
    )
    root_lines = lines[:first_table_index]
    rest_lines = lines[first_table_index:]
    empty_array_line = re.compile(rf'^\s*{re.escape(key)}\s*=\s*\[\s*\]\s*(?:#.*)?(?:\r?\n)?$')
    root_lines = [line for line in root_lines if not empty_array_line.match(line)]
    return "".join([*root_lines, *rest_lines])


def discover_existing_agent_files(agents_dir: Path) -> dict:
    by_id = {}
    if not agents_dir.is_dir():
        return by_id
    for path in sorted(agents_dir.glob("*.toml")):
        try:
            aid = agent_id(path.read_text(encoding="utf-8"))
        except OSError:
            continue
        if aid:
            by_id.setdefault(aid, path)
    return by_id


def agent_file_path(agents_dir: Path, existing_files: dict, aid: str) -> Path:
    return existing_files.get(aid) or agents_dir / (safe_file_stem(aid) + ".toml")


def write_agent_file(path: Path, body: str) -> bool:
    next_body = body.rstrip() + "\n"
    if path.exists() and path.read_text(encoding="utf-8") == next_body:
        return False
    path.write_text(next_body, encoding="utf-8")
    return True


def backup_config_file(path: Path) -> Path:
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_suffix(path.suffix + f".bak-{stamp}")
    suffix = 2
    while backup.exists():
        backup = path.with_suffix(path.suffix + f".bak-{stamp}-{suffix}")
        suffix += 1
    shutil.copy2(path, backup)
    return backup


def ensure_preset_skill_config(text: str, sirix_home: Path) -> str:
    preset_skill_ids = {"sirix-preset-agents", *(agent["id"] for agent in catalog["agents"])}

    def keep_or_remove(match):
        block = match.group(0)
        sid = first_match(r'^\s*id\s*=\s*"([^"]+)"\s*$', block)
        return "" if sid in preset_skill_ids else block

    text = remove_empty_root_array_key(text, "skills")
    text = re.sub(r'(?ms)^\[\[skills\]\]\s*$.*?(?=^\[|\Z)', keep_or_remove, text).rstrip() + "\n"
    text += render_skill_block(
        "sirix-preset-agents",
        "Sirix Preset Agent Routing",
        sirix_home / "skills" / "sirix-preset-agents",
    )
    for agent in catalog["agents"]:
        text += render_skill_block(
            agent["id"],
            agent["name"],
            sirix_home / "skills" / safe_file_stem(agent["id"]),
        )
    return text


original = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
provider_id, model_id = infer_provider_and_model(original)
sirix_home = config_path.parent
agents_dir = sirix_home / "agents"
existing_agent_files = discover_existing_agent_files(agents_dir)

if not original.strip():
    kept = render_default_provider(provider_id, model_id)
else:
    # No compatibility migration here: Agent definitions are owned by
    # SIRIX_HOME/agents/*.toml.  Remove all legacy inline `[[agents]]` blocks
    # and orphaned `[agents.*]` fragments from config.toml so they cannot turn
    # top-level `agents` into a TOML map and break SirixConfig deserialization.
    kept, _removed_agent_blocks = split_config_and_inline_agent_blocks(original)
    kept = kept.rstrip() + "\n"

if re.search(r'(?m)^\s*default_agent_id\s*=', kept) is None:
    if re.search(r'(?m)^\s*version\s*=', kept):
        kept = re.sub(
            r'(?m)^(\s*version\s*=\s*[^\n]+\n)',
            "\\1default_agent_id = \"codex\"\n",
            kept,
            count=1,
        )
    else:
        kept = 'default_agent_id = "codex"\n' + kept
kept = ensure_preset_skill_config(kept, sirix_home)

config_path.parent.mkdir(parents=True, exist_ok=True)
if config_path.exists():
    backup = backup_config_file(config_path)
    print(f"Backup written: {backup}")
config_path.write_text(kept.rstrip() + "\n", encoding="utf-8")
agents_dir.mkdir(parents=True, exist_ok=True)
written_agents = 0
merged_agents = 0

codex_path = agent_file_path(agents_dir, existing_agent_files, "codex")
if override_agents:
    written_agents += int(write_agent_file(codex_path, render_codex_file(provider_id, model_id)))
elif codex_path.exists():
    body = merge_agent_model_and_permissions(
        render_codex_file(provider_id, model_id),
        codex_path.read_text(encoding="utf-8"),
        "codex",
    )
    written_agents += int(write_agent_file(codex_path, body))
    merged_agents += 1
else:
    written_agents += int(write_agent_file(codex_path, render_codex_file(provider_id, model_id)))

for agent in catalog["agents"]:
    aid = agent["id"]
    path = agent_file_path(agents_dir, existing_agent_files, aid)
    default_body = render_agent_file(agent, provider_id, model_id)
    if override_agents:
        written_agents += int(write_agent_file(path, default_body))
    elif path.exists():
        body = merge_agent_model_and_permissions(
            default_body,
            path.read_text(encoding="utf-8"),
            aid,
        )
        written_agents += int(write_agent_file(path, body))
        merged_agents += 1
    else:
        written_agents += int(write_agent_file(path, default_body))
write_preset_skill(sirix_home)
mode = "override" if override_agents else "merge-existing-model-permissions"
print(f"Imported {len(catalog['agents'])} preset agents ({language}) into {agents_dir} [{mode}]")
print(f"Agent files written/updated: {written_agents}; merged existing same-id model/permission fields: {merged_agents}")
print(f"Imported preset Agent routing skill into {sirix_home / 'skills' / 'sirix-preset-agents'}")
print(f"Default Codex provider/model: {provider_id}/{model_id}")
PY
