# 多 Agent、Shell Rules 与 CLI Agent 切换

## 功能说明

本次改动把 Sirix 当前“配置了多 Agent，但运行时并未真正生效”的问题补齐成一条完整链路，主要覆盖三块能力：

- Agent 配置不再只是设置页摆设，Sirix CLI 运行时会真正读取并应用当前 Agent 的模型、系统提示词、MCP、Skills、Builtin Tools、Sub Agent 和 shell 授权模式。
- Sirix CLI 新增 `/agent` 指令，用于展示当前 Session 可用的 Agent 列表并切换当前使用的 Agent；切换后，运行时模型与系统提示词会同步更新。
- Shell 授权规则独立成单独设置项，拆分为全局规则与工作区规则，并支持运行时 `Allow once / session / workspace / global`、`Deny once / session / workspace / global` 以及前缀级持久化授权。

同时补充了 Agent fallback model 能力：当主模型连续失败 3 次后，在当前 Session 内临时禁用 1 小时并切到 fallback model；切换 Agent 后该状态失效。

## 代码位置

### 1. desktop-server 配置、会话与本地 API

- `desktop-server/src/app/ai/config.rs`
  - Agent 配置模型升级为 `description / fallback / approval_mode / builtin_tool_ids / skill_ids / mcp_server_ids / sub_agent_ids`
  - 增加 `ShellRulesConfig`
  - 增加全局与工作区 shell-rules.json 读写、合并与前缀归并逻辑
  - 增加 Agent 系统提示词拼装逻辑，并把 Sub Agent 描述注入最终 prompt
- `desktop-server/src/app/ai/session.rs`
  - 增加 session 级 runtime 状态，记录当前 Agent、Builtin Tools、Shell Rules 与 fallback model 状态
  - 增加 Session 内 Agent 切换与 shell 规则热更新
- `desktop-server/src/api/ai.rs`
  - 新增 `/ai/shell-rules`
  - 新增 `/ai/config/system-prompt-preview`
  - 新增 `/ai/sessions/:ai_session_id/agents`
  - 新增 `/ai/sessions/:ai_session_id/agent`
  - 新增 `/ai/sessions/:ai_session_id/shell-rules/resolve`
  - 增加模型失败计数与 fallback 切换处理
- `desktop-server/src/api/mod.rs`
  - 注册新增 AI / shell rules / session agent API 路由
- `desktop-server/src/app/terminal/manager.rs`
  - 启动 Sirix CLI 时注入 session id、本地 API 地址与 agent runtime 文件路径

### 2. vendored codex runtime

- `third_party/codex-rs/tools/src/tool_config.rs`
- `third_party/codex-rs/tools/src/tool_registry_plan.rs`
  - 根据当前 Agent 的 `builtin_tool_ids` 动态裁剪 builtin tool 暴露面
- `third_party/codex-rs/core/src/exec_policy.rs`
- `third_party/codex-rs/core/src/codex.rs`
- `third_party/codex-rs/protocol/src/protocol.rs`
  - 增加 Sirix runtime shell mode 覆盖与 developer instructions 热更新
- `third_party/codex-rs/tui/src/slash_command.rs`
- `third_party/codex-rs/tui/src/chatwidget.rs`
- `third_party/codex-rs/tui/src/app.rs`
- `third_party/codex-rs/tui/src/app_event.rs`
- `third_party/codex-rs/tui/src/app_command.rs`
- `third_party/codex-rs/tui/src/bottom_pane/approval_overlay.rs`
- `third_party/codex-rs/tui/src/sirix_local_api.rs`
  - `/agent` 改为 Sirix Agent profile 切换
  - `/subagents` 继续保留原线程切换语义
  - shell 授权弹层支持 8 种授权/拒绝选项及命令前缀持久化

### 3. Flutter 设置页与本地 API Client

- `client/packages/infra_api/lib/src/ai_models.dart`
  - Agent / ApprovalMode / ShellRules 的配置模型升级
  - 内置 builtin tools catalog，供设置页选择器使用
- `client/packages/infra_api/lib/src/desktop_local_client.dart`
  - 增加 shell rules 读取与保存接口
  - 增加“系统提示词预览”本地接口调用
- `client/packages/feature_settings_ai/lib/src/ai_settings_state.dart`
- `client/packages/feature_settings_ai/lib/src/ai_settings_view_model.dart`
  - AI 设置状态增加 shell rules，并把保存流程扩展到 config.toml + shell-rules.json
- `client/packages/feature_settings_ai/lib/src/ai_settings_page.dart`
  - 新增 Shell Rules 独立导航项
- `client/packages/feature_settings_ai/lib/src/sections/agent_settings_section.dart`
  - 重写 Agent 页面
  - 增加 Description、Fallback Model、Sub Agent、多选 Builtin Tools / Skills / MCP Servers
  - 增加“预览系统提示词”按钮，并改为通过 desktop-server 生成完整预览
  - 预览内容会展开 Builtin Tools 描述、Skills、Sub Agent，以及 MCP 的实时能力清单
  - 去掉旧的 Capability Rules UI 和编号式标题
- `client/packages/feature_settings_ai/lib/src/sections/shell_rules_settings_section.dart`
  - 新增 Shell Rules 独立设置页

## 实现方法

### 1. Agent 配置真正驱动运行时

以前 Agent 设置更多只停留在桌面端配置层，Sirix CLI 运行时没有完整把这些字段注入进去。现在改成：

1. desktop-server 在启动 AI session 时，根据工作区生成“生效配置”
2. 把当前 Agent 的系统提示词、MCP、Skills、Builtin Tools、Shell Rules 写入 session 运行时文件
3. vendored codex runtime 启动后读取这些 session 文件
4. tool registry、exec policy 和 TUI 弹层都基于当前 Agent 的 runtime 配置工作

这样 Agent 设置、CLI 行为和 Session 实际能力就一致了。

### 2. `/agent` 与 `/subagents` 的职责拆分

本次把两个概念拆开：

- `/agent`：切换当前 Session 使用的 Sirix Agent profile
- `/subagents`：保留原有的线程/子会话切换语义

切换 `/agent` 后会同步更新：

- 当前模型
- developer instructions
- builtin tools 暴露范围
- shell 授权模式

从而避免“列表能切，但运行时上下文没变”的假切换问题。

### 3. Shell Rules 合并与前缀持久化

Shell Rules 独立于 Agent 设置页保存：

- 全局规则：`~/.sirix/shell-rules.json`
- 工作区规则：`<workspace>/.sirix/shell-rules.json`

工作区规则在运行时的计算方式是：

1. 先读取全局规则
2. 再叠加工作区规则
3. 如果前缀冲突，工作区优先

运行时授权时，若用户选择 `Allow session / workspace / global` 或 `Deny session / workspace / global`，会先进入“命令前缀选择”二阶段，再把最终前缀写入对应作用域。对于已存在更细前缀、后续又允许更粗前缀的情况，保存时会做归并，避免规则无限膨胀。

### 4. fallback model 的 Session 级策略

fallback model 只对当前使用该 Agent 的 Session 生效：

- 主模型请求失败计数达到 3 次后，临时禁用 1 小时
- 禁用期间自动回退到 Agent 配置中的 fallback model
- 主模型成功请求后会清空失败计数
- 切换 Agent 会丢弃当前 fallback 状态，不跨 Agent、也不跨 Session 持久化

这样既能在上游模型临时不可用时保证对话继续，又不会把短期故障错误地写成长期配置。

### 5. 系统提示词预览改为后端生成

之前设置页里的“预览系统提示词”只是前端基于配置做静态拼接，因此只能看到：

- builtin tool id 列表
- MCP server 名称
- skill / sub agent 名称

这会丢失真正影响模型理解的大量上下文，例如：

- builtin tool 的用途说明
- MCP server 初始化后暴露出的具体 tool 名称
- tool 的 description
- tool 的 input schema
- resource template / direct resource

现在改为由 `desktop-server` 提供 `/ai/config/system-prompt-preview`：

1. Flutter 设置页把当前草稿配置直接发给 desktop-server
2. desktop-server 根据草稿 Agent 重新组装完整预览文本
3. 对 `stdio` MCP server，会真实启动 server 并执行一次 MCP initialize / tools list / resources list / templates list
4. 把 discovery 结果渲染回预览弹窗

这样预览不再是“能力清单”，而是接近 `kilocode` 风格的完整提示词视图。

当前限制：

- `stdio` MCP 会做实时 discovery，因此可以看到 tool / schema / resource
- `http` MCP 目前先展示 server 元信息与说明文字，还没有做 live discovery

这个限制是为了避免把 `desktop-server` 直接耦合进 vendored `codex-rs` workspace 的重依赖链路里，先保证当前实现稳定可用。
