# 统一权限审批

## 本轮已落地内容

### 1. 非 Shell 权限模型扩展
已把 Sirix 的非 Shell 权限从原本偏扁平的 `tool_rules` 扩展为更明确的三类能力模型：
- `Builtin`
- `Skill`
- `MCP`

同时保留原有 `ShellRulesConfig`，继续让 Shell 走独立的前缀 / exec-policy 逻辑。

对应文件：
- `desktop-server/src/app/ai/config.rs`
- `client/packages/infra_api/lib/src/ai_models.dart`

实现方式：
- 新增 `CapabilityRulesConfig` / `CapabilityApprovalRule`
- 支持全局与 Agent 级配置承载
- 运行时仍然复用 capability key 匹配，而不是另起一套审批引擎

### 2. 运行时审批能力扩展
当前 Desktop Server 的审批解析已能识别：
- `builtin.*`
- `skill.*`
- `mcp.*`
- `builtin.shell`

对应文件：
- `desktop-server/src/api/ai.rs`
- `third_party/codex-rs/core/src/skills.rs`
- `third_party/codex-rs/core/src/codex.rs`

实现方式：
- `desktop-server` 按 `Global -> Agent -> Workspace -> Session` 解析 Builtin / Skill / MCP
- vendored Codex runtime 在 skill 注入阶段增加 Sirix 审批过滤
- skill capability key 采用 `skill.<skill_id>`

### 3. Desktop 设置页补齐
Desktop AI Settings 已新增权限页能力：
- 全局 Builtin 权限
- 全局 Skill 权限
- 全局 MCP 权限
- 全局 Shell 权限
- 全局 Agent 权限入口
- Agent 级 Builtin / Skill / MCP override 已补齐

对应文件：
- `client/packages/feature_settings_ai/lib/src/ai_settings_page.dart`
- `client/packages/feature_settings_ai/lib/src/sections/shell_rules_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/sections/agent_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/ai_settings_state.dart`
- `client/packages/feature_settings_ai/lib/src/ai_settings_view_model.dart`

实现方式：
- 顶级导航从 `Shell Rules` 调整为独立 `Permissions`
- `Permissions` 页内部按 `Builtin / Skills / MCP / Shell / Agents` 顶部 Tabs 分组
- `Allow / Ask / Deny` 统一改成 segmented switch，和 Agent 页 override 保持一致
- 顶级 `MCP` 页保留 transport / server 管理与 discovery 展示，不再承载权限编辑

### 4. MCP discovery 基础能力
Desktop Server 的 MCP 状态探测已扩展为可做 tool discovery：
- `stdio` MCP：尝试 initialize + list_tools
- `http` MCP：尝试 initialize + list_tools
- 发现结果挂到状态概览中

对应文件：
- `desktop-server/src/app/status.rs`
- `client/packages/infra_api/lib/src/models.dart`
- `client/packages/feature_settings_ai/lib/src/sections/mcp_settings_section.dart`

实现方式：
- 基于 `codex-rmcp-client` 建立轻量 discovery client
- 在状态页 / 设置页消费 `discovered_tools`
- 当前 function 级权限 UI 先依赖这个 discovery 结果展示

### 5. Ask 审批多端广播链路
已补充 AI approval request / resolve 的 backend 转发链路：
- Desktop Server 本地事件继续保留
- Desktop Server 会把 request / resolved 同步到 backend
- backend 会广播给：
  - terminal event bus
  - desktop event bus
  - mobile event bus

对应文件：
- `desktop-server/src/api/ai.rs`
- `desktop-server/src/app/tasks.rs`
- `backend-server/src/api/ai_sessions.rs`
- `backend-server/src/api/mod.rs`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
- `client/packages/infra_api/lib/src/backend_api_client.dart`
- `client/packages/infra_api/lib/src/http_backend_api_client.dart`

实现方式：
- 新增 backend 接口：
  - `POST /api/v1/ai-sessions/:id/approval-requests`
  - `POST /api/v1/ai-sessions/:id/approvals/resolve`
- mobile / remote terminal 场景下，`feature_terminal` 也可直接走 backend resolve
- Desktop Server 收到 backend `ai.approval.resolved` 后，会把非 Shell 审批结果同步回本地 approval registry / workspace/global 配置，保证移动端或远端终端审批也能真正解除本地运行中的阻塞

### 6. 审批请求 ID
为降低多端并发审批时的误删/串扰风险，approval event 已开始携带 `request_id`。

对应文件：
- `desktop-server/src/api/ai.rs`
- `backend-server/src/api/ai_sessions.rs`
- `client/packages/feature_terminal/lib/src/terminal_state.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
- `client/packages/infra_api/lib/src/desktop_local_client.dart`

实现方式：
- request event 生成 `request_id`
- resolved event 回传 `request_id`
- 客户端优先按 `request_id` 做去重和清除，缺失时再回退到旧的 `(session, agent, capability)` 维度

## 7. Shell 审批多端协同与复杂命令边界
Shell 继续保留独立的前缀 / exec-policy 规则体系，但 Ask 场景已补齐到 CLI / Desktop / Mobile 的统一广播与收敛：
- CLI 仍使用 Codex TUI 原生审批弹层
- Desktop / Mobile 通过 `ai.approval.request` / `ai.approval.resolved` 接收与消除同一审批请求
- Desktop Server 新增 shell approval registry，负责在 CLI 与远端审批之间做桥接
- 任一端批准 / 拒绝后，其它端会收到 resolved 事件并清除同一请求

对应文件：
- `desktop-server/src/app/ai/approval.rs`
- `desktop-server/src/api/ai.rs`
- `desktop-server/src/app/tasks.rs`
- `third_party/codex-rs/tui/src/app.rs`
- `third_party/codex-rs/tui/src/bottom_pane/approval_overlay.rs`
- `third_party/codex-rs/tui/src/sirix_local_api.rs`
- `client/packages/feature_terminal/lib/src/terminal_page.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`

实现方式：
- TUI 收到 shell exec approval 时，会镜像一份 shell approval request 到 Desktop Server
- Desktop Server 再把请求广播给本地桌面端与 backend（从而到 mobile）
- 远端批准后，TUI 轮询本地 API 读取 shell resolution，并自动把 approval 回注给运行中的 Codex turn
- 复杂 shell / 解释器命令只暴露 `once / session` 两种 scope；其中 `session` 默认只允许当前完整命令前缀，不允许提升到 workspace/global
- 简单 shell 命令仍可选择更短的 prefix，并支持 `session / workspace / global`

## 8. MCP 权限与子 Function 展示
MCP 权限页和 MCP 管理页已分离：
- `Permissions -> MCP` 负责 server / function 级审批配置
- `MCP` 顶级页只负责 transport、server 管理和 discovery 展示
- 每个 MCP server 可通过 `Info` 弹窗查看已发现的子 function 详情

对应文件：
- `client/packages/feature_settings_ai/lib/src/sections/mcp_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/sections/shell_rules_settings_section.dart`
- `desktop-server/src/app/status.rs`

实现方式：
- MCP 总开关与子 function 权限统一映射为 capability key
- server 级规则可默认下沉到子 function，再允许子 function 独立覆盖
- discovery 结果通过 Desktop Server 的 status overview 回传前端，用于权限页与信息弹窗展示

## 相关文件
- `desktop-server/src/app/ai/config.rs`
- `desktop-server/src/api/ai.rs`
- `desktop-server/src/app/ai/approval.rs`
- `desktop-server/src/app/status.rs`
- `desktop-server/src/app/tasks.rs`
- `backend-server/src/api/ai_sessions.rs`
- `client/packages/feature_settings_ai/lib/src/sections/shell_rules_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/sections/agent_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/sections/mcp_settings_section.dart`
- `client/packages/feature_terminal/lib/src/terminal_page.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
- `client/packages/infra_api/lib/src/ai_models.dart`
- `client/packages/infra_api/lib/src/backend_api_client.dart`
- `client/packages/infra_api/lib/src/desktop_local_client.dart`
- `third_party/codex-rs/core/src/skills.rs`
- `third_party/codex-rs/core/src/codex.rs`
- `third_party/codex-rs/tui/src/app.rs`
- `third_party/codex-rs/tui/src/bottom_pane/approval_overlay.rs`
