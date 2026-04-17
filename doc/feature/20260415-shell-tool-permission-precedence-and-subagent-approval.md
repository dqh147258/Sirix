# Shell / Tool 权限优先级与 SubAgent Ask 审批

## 功能说明

本次改动把 Sirix 的 Shell 权限与 Tool 权限统一到同一套优先级和审批语义下，并补齐 SubAgent 在 `Ask` 模式下的权限请求链路。

主要目标：

- Shell / Tool 权限统一按 `Global -> Agent -> Workspace -> Session` 的层级理解冲突覆盖关系
- `Allow / Ask / Deny` 三种模式分别按用户要求启用黑名单、白名单或两者
- 高优先级规则不仅覆盖同名项，也会覆盖其完整包含的低优先级前缀规则
- builtin tool 和 MCP tool 调用在 Sirix 运行时下都会主动走本地审批 API，而不是各自分散审批
- SubAgent 在 `Ask` 模式下会以自己的 agent 身份请求审批，不再只沿用父 Agent 的运行时身份

## 代码位置

- `desktop-server/src/app/ai/config.rs`
  - 新增 `ToolRulesConfig`
  - 新增全局 / 工作区 `tool-rules.json` 读写
  - Shell 规则生效顺序调整为 `Global -> Agent -> Workspace -> Session`
  - Tool 规则生效顺序实现为 `Global -> Agent -> Workspace`
  - 规则冲突裁剪改为“高优先级粗前缀覆盖低优先级细前缀”
  - 生成 bridge / role config 时写入 `sirix_agent_id` 与 `sirix_shell_mode`
- `desktop-server/src/api/ai.rs`
  - `POST /ai/sessions/approvals/check` 支持可选 `agent_id`
  - approval request / resolved 事件会带当前实际请求的 `agent_id`
  - `builtin.shell`、`builtin.<tool>`、`mcp.<server>.<tool>` 分别按 Shell / Tool 规则解析
  - 新增 `/ai/tool-rules` 的全局读写接口
- `desktop-server/src/api/mod.rs`
  - 注册 `/ai/tool-rules`
- `desktop-server/src/app/ai/approval.rs`
  - approval cache 与 pending request 改为按 `ai_session_id + agent_id + capability_key` 隔离
  - 避免一个 SubAgent 的审批结果误命中另一个 SubAgent
- `third_party/codex-rs/config/src/config_toml.rs`
  - 允许 role config 反序列化 `sirix_agent_id` / `sirix_shell_mode`
- `third_party/codex-rs/core/src/config/mod.rs`
  - 将 `sirix_agent_id` / `sirix_shell_mode` 挂进运行时 `Config`
- `third_party/codex-rs/core/src/exec_policy.rs`
  - shell fallback mode 优先读取当前线程 `Config.sirix_shell_mode`
  - 只有缺省时才回退到 `SIRIX_AGENT_RUNTIME_PATH` 指向的 runtime 文件
- `third_party/codex-rs/core/src/tools/registry.rs`
  - 在 builtin function tool 分发前调用 Sirix 本地审批 API
  - `Ask` 时轮询等待用户决策
  - `Deny` 时直接阻断工具调用
- `third_party/codex-rs/core/src/mcp_tool_call.rs`
  - 在 MCP tool call 前调用同一套 Sirix 本地审批 API
  - 普通授权交给 Sirix Tool Rules，ARC / guardian 安全链路继续保留
- `third_party/codex-rs/core/src/sirix_tool_approval.rs`
  - 抽出 Sirix 本地工具审批轮询 helper，供 builtin / MCP 共用
- `client/packages/infra_api/lib/src/ai_models.dart`
  - `AgentConfigModel` 增加 `toolRules`
  - 避免桌面端保存 AI 配置时丢失 Agent 级 Tool Rules

## 实现方法

### 1. Shell / Tool 规则合并

Shell 与 Tool 规则都复用 `mode / allow / deny` 三元结构。

实现上：

- Shell 权限在启动 Session 时被转换为 exec policy 前缀规则
- Tool 权限在运行时通过 capability key 匹配
  - builtin: `builtin.<tool_id>`
  - MCP: `mcp.<server>.<tool_id>`
- 若更高优先级层新增了相反方向的更粗规则，会清理掉被其完整覆盖的低优先级反向规则

例子：

- Global `allow = ["find . -name"]`
- Agent `deny = ["find"]`
- 合并后低优先级的 `find . -name` 会被移除，最终保留 `deny = ["find"]`

### 2. builtin / MCP tool 审批

`third_party/codex-rs/core/src/tools/registry.rs` 与 `third_party/codex-rs/core/src/mcp_tool_call.rs` 会在工具真正执行前：

1. 生成 capability key
   - builtin: `builtin.<tool_name>`
   - MCP: `mcp.<server>.<tool_name>`
2. 读取 `SIRIX_LOCAL_API_BASE` 与 `SIRIX_AI_SESSION_ID`
3. 调用 `POST /ai/sessions/approvals/check`
4. 如果结果是：
   - `allow`：直接继续执行
   - `deny`：直接向模型返回拒绝
   - `ask`：轮询等待用户在 Sirix UI 中完成审批

shell 类工具 `shell / shell_command / exec_command / write_stdin` 不在这里重复审批，继续沿用原有 shell exec-policy 流程。

MCP 额外说明：

- Sirix 工具审批通过后，MCP 调用仍保留 Codex 自带的 ARC / guardian 安全链路
- 这样普通授权统一收敛到 Sirix 的 Tool Rules，而高风险调用仍保留额外安全兜底

### 3. SubAgent Ask 身份隔离

Sirix 在 bridge config 和每个 role config 中额外写入：

- `sirix_agent_id`
- `sirix_shell_mode`

这样 `codex-rs` 内部线程在处理 builtin / MCP tool 审批时，可以带上当前 SubAgent 的 `agent_id` 去调用本地审批 API，桌面端就能按对应 Agent 的 Tool Rules / Shell fallback mode 解析，而不是错误地把子线程继续当作父 Agent。

另外桌面端的 approval registry 也同步改成按 `agent_id` 隔离：

- 缓存命中不再只看 `session_id + capability_key`
- pending request 去重也不再只看 capability
- UI 收到的审批事件会显示真实发起审批的 SubAgent

这样一个 SubAgent 的 once / session / deny 结果就不会串到另一个 SubAgent。

### 4. Shell fallback mode 真正按当前线程角色生效

最初只把 `sirix_shell_mode` 写进了 role config，但真正的 shell fallback 判定仍然只读 session runtime env 文件。

这次修正后：

- `codex-rs` 在执行 unmatched shell command fallback 判定时
- 会优先读取当前线程 `Config` 上的 `sirix_shell_mode`
- 只有当前线程没有显式值时，才回退到 runtime env 文件

这样 SubAgent 的 shell fallback mode 才会真正和自己的角色配置保持一致，而不是继续继承父 Agent。

## 结果

当前行为变为：

- Shell 权限、Tool 权限都遵循统一的多层覆盖逻辑
- Tool 权限不再只是“配置可保存”，而是已经真正进入 builtin 与 MCP 的运行时审批路径
- SubAgent 在 `Ask` 模式下具备独立审批能力，且审批缓存、pending 状态、UI 展示都按 agent 隔离
- SubAgent 的 shell fallback mode 会按自己的角色配置生效，不再错误继承父 Agent
- Flutter 配置 round-trip 不会再丢失 `tool_rules`
