# 预置 Agent JSON 配置与一键导入

## 功能概述

应用现在通过 JSON 数据源维护一组通用预置 Agent 模板，并在全局 AI 配置首次创建时写入 `SIRIX_HOME/agents/*.toml`。预置角色覆盖需求规划、实现计划、只读问答、代码搜索、任务调度、Bug 分析、代码 Review、代码编写和通用自动化 Debug 等协作场景。

这些 Agent 是通用模板，不绑定当前代码仓库的工程特性；提示词只描述通用工作方式、证据要求和输出契约。用户仍可在设置中调整或删除。

Agent 配置不再以内联 `[[agents]]` 保存在 `config.toml` 中。Desktop API 仍返回合并后的 `agents` 列表给设置页，保存时再拆分回 `agents/*.toml`，从而保持 Desktop App 和 `sirix` CLI 的使用方式不变。

## 代码位置

- `desktop-server/resources/preset_agents.json`
  - 预置 Agent 的唯一数据源。
  - 每个 Agent 包含英文/中文 `description` 和 `system_prompt`，以及 `builtin_tool_ids`、`enabled`。
  - 支持 `skills_enabled` / `skill_ids`、`mcp_servers_enabled` / `mcp_server_ids`、`sub_agents_enabled` / `sub_agent_ids` 三组资源开关：
    - `*_enabled = false` 表示该 Agent 禁止使用对应能力。
    - `*_enabled = true` 且 ID 列表为空时，运行时按 Global + Workspace 合并后的可用资源开放全部可用项。
    - `*_enabled = true` 且 ID 列表非空时，仅开放列表内资源。
  - 预置 Agent 默认不固定 `provider_id` / `model_id`，运行时继承模型设置页中唯一的 CLI 默认模型；需要固定模型时可在 Agent 编辑页或导入脚本中显式填写。
  - 预置调度 Agent 不配置也不向 `spawn_agent` 传递推理档位；如旧上下文或手写 role 残留 `reasoning_effort`，运行时会在目标模型不支持时清空并回退到模型默认行为，避免 GLM/Qwen 等 Provider 因无推理档位列表而调度失败。
  - 默认导入语言为 `en`。
  - Code Review 相关 Agent 支持审查未提交修改、指定 git commit/range、类似 PR 的 diff，或某个功能实现。
  - Debugger 是通用自动化调试专家，不包含任何特定工程日志路径或脚本约定。
- `desktop-server/src/app/ai/preset_agents.rs`
  - 使用 `include_str!` 嵌入 JSON，反序列化为 `PresetAgentCatalog`。
  - 提供首次启用所需的默认语言、预置 Agent 列表和默认主 Agent 子角色列表。
- `desktop-server/src/app/ai/config.rs`
  - `SirixConfig::default()` 使用 JSON catalog 生成 `codex` + 全部预置 Agent。
  - `SirixConfigStore::load_global()` / `save_global()` 将全局 Agent 配置读写到 `SIRIX_HOME/agents/*.toml`，`config.toml` 只保留 provider、skill、MCP、默认 Agent 等非 Agent 配置。
  - Workspace 设置同样支持 `<workspace>/.sirix/agents/*.toml`；旧的内联 `[[agents]]` 会在下次保存时迁移到文件目录。
  - `ensure_layout()` 会创建 `SIRIX_HOME/agents/`，生成总路由 Skill `SIRIX_HOME/skills/sirix-preset-agents/SKILL.md`，并为每个预置 Agent 生成独立 Skill：`SIRIX_HOME/skills/<agent-id>/SKILL.md`。
  - `SIRIX_HOME/skills/sirix-preset-agents/agents/<agent>.md` 继续保留每个预置 Agent 的说明索引；独立 Skill 里会嵌入对应 Agent 的调度说明和系统提示词。
  - 生成的每个 `SKILL.md` 都带 Codex Skill loader 要求的 YAML frontmatter，`name` 使用 Agent ID（例如 `debugger`），确保 Sirix CLI `/skills` 的 List skills 与 `$<agent-id>` 唤醒都能识别预置 Skill。
  - `load_global()` 会自动注册预置 Skill `sirix-preset-agents` 以及每个预置 Agent 同名 Skill，用于支持 `$debugger`、`$orchestrator` 等快速唤醒。
  - 首次生成的 `codex` 默认 `sub_agent_ids` 指向核心预置专家，使初始会话可以直接委托这些角色。
  - 新增 `default_agent_id`，用于控制启动 `sirix` CLI 且未显式传入 Agent 时默认使用的 Agent。
  - Workspace 配置也可写入 `default_agent_id`；当 Workspace 设置了默认 Agent 时优先级高于 Global 默认 Agent。
  - Workspace 配置中的空 `default_agent_id` 是“继承 Global 默认 Agent”的显式语义，加载和保存 Workspace 设置时不会再被归一化成 `codex`。
  - Effective Workspace 配置读取时会同时加载 `<workspace>/.sirix/agents/*.toml`，保证文件化 Agent 覆盖和新增项会参与 Global + Workspace 合并。
  - Agent 的 `provider_id` / `model_id` 允许为空；为空或引用已删除模型时，`build_launch_config`、角色文件生成和 Prompt Preview 都会解析到模型设置页中唯一的 CLI 默认模型。
  - Agent 新增 `model_reasoning_effort`，默认 `high`；生成根 Agent bridge config 和 SubAgent role config 时会写入该档位。若模型元数据明确 `supported_reasoning_efforts = []`，则不写入推理档位，避免不支持的模型失败；若元数据缺失则视为无法判断，保留用户选择。
  - Codex bridge 在导出 Skills、MCP servers、SubAgents 时统一执行 Agent 级开关与 ID allowlist 规则。
  - 新增单元测试 `global_agents_are_persisted_under_sirix_home_agents`，验证保存后 Agent 不再内联到 `config.toml`，而是落到 `SIRIX_HOME/agents/`。
  - 新增单元测试 `ensure_layout_writes_preset_agent_skill_docs`，验证总路由 Skill、每个 Agent 的说明索引以及独立 Agent Skill 会被生成。
- `scripts/import-preset-agents.sh`
  - 一键导入脚本，可将 JSON 中的预置 Agent 写入 `SIRIX_HOME/agents/*.toml`。
  - 支持 `--language en|zh`，默认英文。
  - 支持 `--provider-id`、`--model-id`、`--sirix-home`、`--config`、`--no-update-codex` 和 `--override`。
  - 默认不为预置 Agent 写死 provider/model；`codex` 仍会使用配置中的默认 provider/model。传入 `--provider-id` 或 `--model-id` 时会固定新导入的预置 Agent；已有同 ID Agent 默认继续保留用户配置的模型字段。
  - 已存在配置会先生成唯一时间戳 `.bak-*` 备份；重复导入默认用最新预设覆盖名称、说明、提示词等主体内容，但保留同 ID Agent 的模型与权限/能力配置（例如 `provider_id`、`model_id`、`approval_mode`、工具/Skill/MCP/SubAgent allowlist、启用状态等）。
  - 传入 `--override` 时，不再继承同 ID Agent 的模型与权限字段，直接用预设目录默认值覆盖。
  - 同步导入总路由 Skill 到 `SIRIX_HOME/skills/sirix-preset-agents/`，并为每个预置 Agent 写入同名独立 Skill 目录，便于用 `$<agent-id>` 快速唤醒。
  - 导入前会清理根级空数组 `skills = []`，再追加 `[[skills]]` 数组表，避免 TOML 同一个 `skills` 键先作为普通数组、后作为数组表导致 `duplicate key` 解析失败。
  - 生成的 Skill 文件同样写入 YAML frontmatter，避免 Codex loader 因 `missing YAML frontmatter delimited by ---` 跳过预置 Skill。
- `scripts/migrate-sirix-agents-to-files.sh`
  - 专门负责一次性迁移旧版 `config.toml` 中的内联 `[[agents]]` 配置到 `SIRIX_HOME/agents/*.toml`。
  - 迁移时会把附属于 Agent 的 `[agents.*]` / `[[agents.*]]` 子表改写成 Agent 文件内的 `[builtin_approvals]` / `[[builtin_approvals.rules]]` 等普通子表。
  - 已存在同 ID Agent 文件时默认不覆盖，传入 `--override-agent-files` 才覆盖；迁移后会从 `config.toml` 移除内联 Agent 和无归属的孤立 `agents.*` 段。
  - 用于修复旧迁移残留造成的 `invalid type: map, expected a sequence` 错误；导入脚本不再承担旧内联 Agent 兼容迁移职责。

- `third_party/codex-rs/core-skills/src/loader.rs`、`third_party/codex-rs/core-skills/src/config_rules.rs`
  - Sirix bridge 会把 `SIRIX_HOME/skills/<skill-id>` 写入 `[[skills.config]].path`；Codex 原生 `/skills` 只扫描 `CODEX_HOME/skills`、插件和仓库 `.agents/skills`。
  - 现在 Skills loader 会把 `[[skills.config]].path` 中的显式 Skill 目录或 `SKILL.md` 文件也作为 User scope roots 扫描，因此位于 `SIRIX_HOME/skills` 的预设 Skills 能出现在 Sirix CLI `/skills` 列表。
  - 禁用规则会把目录形态路径归一到对应 `SKILL.md`，保证 Agent 级 `skills_enabled / skill_ids` 过滤后，List skills 中的 enabled 状态与实际可用性一致。

- `third_party/codex-rs/tui/src/slash_command.rs`、`third_party/codex-rs/tui/src/app.rs`、`third_party/codex-rs/tui/src/chatwidget.rs`
  - 新增 `/subagent` 单数命令，用于列出当前 Agent 可调度的 Sirix SubAgent 角色；原 `/subagents` 保持为已生成子线程切换入口，避免语义混淆。
  - `/subagent` Picker 直接读取当前 bridge config 中的 `[agents.<role>]`（即当前 Agent 经过 `subAgentsEnabled` / `subAgentIds` 过滤后的可委托角色），选择后会在输入框预填 `/subagent <role> `。
  - 用户继续输入任务并回车后，TUI 会把该命令转换为显式的 native `spawn_agent` 调度意图，让父 Agent 调度所选 role，而不是把 `/subagent` 原样发送成普通对话。
  - 切换 Sirix Agent 后会刷新 TUI 内存中的 bridge config，确保 `/subagent` 列表跟随当前 Agent 更新。
- `client/packages/infra_api/lib/src/ai_models.dart`
  - AI 配置模型新增 `defaultAgentId` 字段。
  - Model 配置模型新增可选 `supportedReasoningEfforts`；`null` 表示无法判断，空列表表示明确不支持。
  - Agent 配置模型新增 `skillsEnabled`、`mcpServersEnabled`、`subAgentsEnabled` 和 `modelReasoningEffort` 字段，保证设置页读写不会丢失开关和推理档位。
- `client/packages/feature_settings_ai/lib/src/sections/agent_settings_section.dart`
  - Agent 设置页不再提供独立“默认模型”开关；Provider / Model 下拉框内可直接选择 CLI 默认模型或固定到具体模型，同时保留 Skills / MCP / SubAgents 的启用开关。
  - Agent 设置页在主模型选择后提供 Reasoning Effort 下拉框，默认 High；当所选模型明确不支持推理档位时隐藏，无法判断时保留选择。
  - Agent 详情页新增 “Set as Default” 能力；Workspace 设置页中点击后写入 Workspace 级默认 Agent，优先于 Global 默认 Agent。
  - 空 allowlist 在 UI 中显示为 “All available”，与运行时语义一致。
- `client/packages/feature_settings_ai/lib/src/ai_settings_view_model.dart`
  - 客户端本地兜底合成 `codex` Agent 时，只引用当前配置里已经存在的核心预置专家 ID，避免产生悬空 `sub_agent_ids`。

## 预置 Agent ID

- `product-planner`
- `product-planner-lite`
- `product-planner-pro`
- `implementation-planner`
- `ask`
- `code-searcher`
- `orchestrator`
- `bug-fix-coordinator`
- `bug-fix-lite`
- `bug-fix-pro`
- `code-review-coordinator`
- `code-review-lite`
- `code-review-pro`
- `senior-engineer`
- `debugger`

## 一键导入示例

```bash
# 默认英文导入到 $SIRIX_HOME/config.toml 或 ~/.sirix/config.toml
scripts/import-preset-agents.sh

# 导入中文提示词
scripts/import-preset-agents.sh --language zh

# 指定配置文件，并固定导入的预置 Agent 模型
scripts/import-preset-agents.sh \
  --config /path/to/config.toml \
  --language en \
  --provider-id openai \
  --model-id gpt-5

# 只导入 Agent，不更新 codex 的 sub_agent_ids
scripts/import-preset-agents.sh --no-update-codex

# 完全覆盖同 ID 预设 Agent，不保留用户模型/权限配置
scripts/import-preset-agents.sh --override

# 一次性迁移旧 config.toml 内联 Agent 到 agents/*.toml
scripts/migrate-sirix-agents-to-files.sh --sirix-home ~/.sirix
```

## 兼容性说明

- 首次启用逻辑使用嵌入式 JSON，不依赖运行时资源路径；运行时会把可编辑 Agent TOML 和 Skill 文档写入 `SIRIX_HOME`。
- 一键导入脚本使用 Bash + Python 标准库，适合本地开发/运维导入；桌面端首次启用仍由 Rust 默认配置负责。
- 已有内联 `[[agents]]` 的 `config.toml` 不再由导入脚本兼容迁移；需要先运行 `scripts/migrate-sirix-agents-to-files.sh` 做一次性迁移。
- 旧配置如果由 Sirix 空列表序列化出根级 `skills = []`，导入脚本会在写入预置 Skill 表前移除该空占位，保留其它非预置 Skill 表，保证重复导入后的 `config.toml` 可被 TOML 解析器直接读取。
- `[[skills.config]].path` 支持目录和 `SKILL.md` 两种形态：目录用于 Sirix 管理的可编辑 Skill，`SKILL.md` 路径兼容 Codex 原生管理 Skills 的写法。
- 预置 Agent 是普通配置项，不增加不可删除标记。
- 旧配置中的 `skill_ids`、`mcp_server_ids`、`sub_agent_ids` 继续作为 allowlist 生效；新增的 `*_enabled` 字段缺省为 `true`，因此未设置开关的旧配置仍可启动。

## 验证

- `cargo fmt --manifest-path desktop-server/Cargo.toml`
- `cargo test --manifest-path desktop-server/Cargo.toml default_config_seeds_editable_specialist_agents`
- `cargo test --manifest-path desktop-server/Cargo.toml ensure_layout_writes_preset_agent_skill_docs -- --nocapture`
- `cargo test --manifest-path third_party/codex-rs/Cargo.toml -p codex-core-skills explicit_skill_directory -- --nocapture`
- `cargo test --manifest-path desktop-server/Cargo.toml embedded_catalog_has_bilingual_prompts`
- `cargo test --manifest-path desktop-server/Cargo.toml agent_resource_switches_support_all_allowlist_and_disabled_modes`
- `cargo test --manifest-path desktop-server/Cargo.toml bridge_injects_sirix_sub_agents_as_codex_roles`
- `cargo test --manifest-path desktop-server/Cargo.toml workspace_default_agent_overrides_global_cli_default`
- `cargo test --manifest-path desktop-server/Cargo.toml workspace_empty_default_agent_id_keeps_inheriting_global_default`
- `cargo test --manifest-path desktop-server/Cargo.toml workspace_catalogs_add_global_resources_instead_of_replacing_them`
- `cargo test --manifest-path desktop-server/Cargo.toml agent_reasoning_effort_defaults_to_high_and_hides_known_unsupported_models`
- `cargo test --manifest-path desktop-server/Cargo.toml bridge_writes_agent_reasoning_effort_only_when_model_allows_or_unknown`
- `cargo test --manifest-path desktop-server/Cargo.toml agent -- --nocapture`
- `cargo test --manifest-path third_party/codex-rs/Cargo.toml -p codex-tui subagent -- --nocapture`
- `bash -n scripts/import-preset-agents.sh`
- `scripts/import-preset-agents.sh --sirix-home /tmp/... --language en`
- `cargo check --manifest-path desktop-server/Cargo.toml`
- `flutter analyze client/packages/feature_settings_ai/lib/src/ai_settings_view_model.dart`
- `flutter analyze client/packages/feature_settings_ai/lib/src/sections/agent_settings_section.dart client/packages/infra_api/lib/src/ai_models.dart`
