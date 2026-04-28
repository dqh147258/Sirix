# CLI Approval Stability

## 功能概述

修复 `sirix` / `sirix-terminal` 在 raw terminal 附着共享终端时的审批交互稳定性，重点保证 CLI 本地提示可见、可退出，并继续沿用 Desktop、Mobile、CLI 三端共享的同一套审批事件与 resolve 语义。

## 涉及代码

- `desktop-server/src/cli_approval.rs`
  - 维护 CLI 本地审批 prompt 队列、选项渲染、按键解析与 resolve 提交。
  - 审批 prompt 改为参考 Codex `ApprovalOverlay` / `ListSelectionView` 的 bottom-pane 菜单效果：不清屏、不清 scrollback，只对本地审批菜单行做 cursor-up + clear-line 的局部重绘。
  - 使用 Codex 风格的标题、选项文案、cyan bold 当前项、dim key hint；普通选项保持默认前景色，不再使用黄色，并在菜单中明确显示 Requested function / Function type / Capability key。
  - 支持 `↑/↓`、`j/k` 移动选择，`Enter` 确认；每个选项显示数字编号，数字键和 `y/a/p/g/n/d` 作为 raw terminal 兼容快捷键保留。
  - `Esc` 明确映射为 `deny once` / cancel 当前审批。
  - `Ctrl+C` 明确映射为本地 detach，不提交审批结果，不改后端 pending 状态。
  - 只在 400/404/409 这类 stale resolve 场景清理本地 prompt；网络错误或服务端错误会重新渲染 prompt，避免误伤共享审批状态。

- `desktop-server/src/bin/sirix.rs`
  - 审批 pending 时优先把 stdin 交给 `CliApprovalPrompt`，按 `ApprovalInputAction` 决定继续消费或本地 detach。
  - 审批 pending 时将 `terminal.output` / `terminal.snapshot` / binary terminal frame 暂存到本地 buffer，审批结束后 replay，避免远端 PTY 输出插入菜单中间造成双视图，同时不永久吞掉输出。
  - 新增 `UserDetached` detach reason，退出 raw terminal 后给出明确提示。

- `desktop-server/src/bin/sirix-terminal.rs`
  - 与 `sirix.rs` 保持同样的审批输入和本地 detach 语义。

- `desktop-server/src/api/ws.rs`
  - raw system-terminal websocket 转发 approval 事件时，除 `terminal_id` 外也支持通过 `ai_session_id` 映射到 attached terminal。
  - 这保证 sub-agent / backend sync 路径缺少 `terminal_id` 时，CLI 仍能收到并显示审批菜单。

- `desktop-server/src/app/ai/config.rs`
  - Shell fallback mode 现在按 `Workspace > Agent > Global` 的有效优先级写入 session runtime 与 sub-agent role config。
  - 无 Workspace override 时，Agent `Ask` 不再因为全局 `shell-rules.json` 为 `allow` 而退化成 `sirix_shell_mode = "allow"`；有 Workspace Shell Permission 时，Workspace 仍优先覆盖 Agent。

- `desktop-server/src/api/ai.rs`
  - `/ai/sessions/approvals/check` 对 `builtin.shell` 的 fallback mode 复用同一套 runtime / role 解析，保证 Code Searcher 等 sub-agent 配置为 Ask 时 HTTP approval bridge 与实际执行策略一致。

- `desktop-server/src/cli_approval_display.rs`
  - 承载 Codex 风格菜单行构建、选项文案映射、功能名称展示、ANSI 可见宽度统计与软换行行数计算，避免 `cli_approval.rs` 超过单文件职责边界。

- `desktop-server/src/cli_approval_tests.rs`
  - 承载 CLI approval 单元测试，避免 `cli_approval.rs` 继续膨胀。

## 三端审批语义

本次修复不改变后端审批协议，不改变 Desktop / Mobile / CLI 三端共享的 pending / resolved 机制：

- 审批请求仍由后端通过 `ai.approval.request` 广播到所有端。
- 任一端成功调用 `/ai/sessions/approvals/resolve` 后，后端仍广播 `ai.approval.resolved`。
- 其它端收到 resolved 事件后会移除匹配的 active / queued prompt。
- CLI 的 `Ctrl+C` 只是退出本地 raw terminal 附着，不提交 allow/deny，因此不会抢占或破坏其它端继续审批的能力。

## 实现要点

- 对齐 Codex 原生颜色语义：标题使用 Codex 风格问题句并加粗，当前选项使用 cyan bold，普通选项使用默认前景色，底部 key hint 使用 dim。
- CLI 审批菜单不再使用 ANSI 全屏清屏/清 scrollback；重绘时按终端宽度统计 ANSI 去除后的可见软换行行数，再清理上一轮本地菜单占用的所有视觉行，避免截图中多份 overlay 叠加。
- 选项文案从 `allow/deny + scope` 的技术字符串调整为 Codex 风格文案，例如 shell 审批显示 `Yes, proceed`、`No, continue without running it`、`Yes, and don't ask again...`。
- 队列中的审批不再追加散乱文本，而是在菜单内显示 `Queued approvals` 数量；同一 session + agent + capability 即使携带新的 request_id 重播，也会被视为同一个 pending prompt 去重。
- 菜单明确展示授权对象：shell 显示 `Requested function: Shell command` 和 `$ command`；非 shell 显示 `Requested function`、`Function type`、`Capability key`，例如 `builtin.list_mcp_resources` 会展示为 Built-in tool 下的 `list_mcp_resources`。
- 保持原有 shell / capability approval scopes：shell 通常为 `once`、`session`，存在 exec-policy amendment 时可出现 `workspace`、`global`；非 shell capability 支持 `once`、`session`、`workspace`、`global`，由后端 `supported_scopes` 下发。

## 验证

- `cd desktop-server && cargo test cli_approval`
  - 覆盖不清屏、CRLF、防黄色 warning、Codex 风格颜色、数字编号、功能名称展示、箭头键局部重绘、软换行视觉行清理、重复 request 去重、队列推进、stale queued request 清理等 CLI prompt 行为。
- `cd desktop-server && cargo test raw_terminal_filter`
  - 验证 raw CLI 能按 `ai_session_id` 收到 sub-agent approval 事件。
- `cd desktop-server && cargo test resolve_shell_capability_mode_uses_agent_authorization_directly`
  - 验证 approval check API 的 shell fallback 先使用 Agent Authorization 且不被 Global Allow 降级。
- `cd desktop-server && cargo test agent_shell_authorization_ask_overrides_allow_shell_rules_for_runtime`
  - 验证 Agent Ask 不再被全局 shell allow 覆盖。
- `cd desktop-server && cargo test workspace_shell_authorization_overrides_agent_runtime_fallback`
  - 验证 Workspace Shell Permission 仍覆盖 Agent fallback。
- `cd desktop-server && cargo test bridge_injects_sirix_sub_agents_as_codex_roles`
  - 验证 sub-agent role config 写出 `sirix_shell_mode = "ask"`。
- `cd desktop-server && cargo check`

当前验证通过；输出中仍有项目既有 dead_code / unused warnings。

## 2026-04-26 补充：Ask Shell 被 Codex Never 策略提前拒绝

### 问题

`Code Searcher` 等 sub-agent 的 Shell 权限即使在 Sirix 配置中设为 `Ask`，仍可能在执行前直接失败，错误类似：

`approval required by policy, but AskForApproval is set to Never`

根因是 Sirix 为了避免嵌入式 Codex 的通用审批绕过 Desktop / Mobile / CLI 三端共享审批链路，桥接配置仍将 Codex 原生 `approval_policy` 写为 `never`；但 Shell Ask 会通过 `sirix_shell_mode = "ask"` 转成 Codex exec-policy 的 `Decision::Prompt`。此前 Codex core 在生成 prompt 后又统一检查 `AskForApproval::Never`，导致请求还没镜像到 Sirix approval registry 就被拒绝，因此 CLI/桌面/移动端都看不到审批。

### 修复

- `third_party/codex-rs/core/src/exec_policy.rs`
  - 新增 `sirix_shell_mode_requests_prompt()`。
  - 当 `sirix_shell_mode` 明确为 `ask` 时，允许 shell `Decision::Prompt` 继续生成 approval request，不再被全局 `AskForApproval::Never` 提前拦截。
  - 保留 `approval_policy = never` 对非 Sirix Shell Ask 提示的拦截，避免破坏 Sirix 三端共享审批的唯一入口。

- `third_party/codex-rs/core/src/tools/runtimes/shell/unix_escalation.rs`
  - 同步修复 zsh fork / execve 拦截路径，避免该路径下 Shell Ask 仍被 Never 策略直接 deny。

- `third_party/codex-rs/core/src/exec_policy_tests.rs`
  - 新增 `sirix_shell_ask_can_prompt_even_when_codex_policy_is_never`，锁定 `approval_policy=Never + sirix_shell_mode=ask` 必须返回 `NeedsApproval`。

### 追加验证

- `cargo test -p codex-core sirix_shell_ask_can_prompt_even_when_codex_policy_is_never --manifest-path third_party/codex-rs/Cargo.toml`

## 2026-04-27 补充：Sirix 作为唯一审批权威

### 目标

三端共享审批（Desktop / Mobile / CLI 任一端通过后，其它端自动消失并继续）是 Sirix 的核心审批模型。嵌入式 Codex 的 `approval_policy`、sandbox retry、network approval、additional permissions 等旧策略不能再作为独立审批权威，也不能在 Sirix 发布审批请求前提前拒绝。

### 实现

- `third_party/codex-rs/core/src/sirix_tool_approval.rs`
  - 新增 `sirix_approval_authority_enabled()`：以 `SIRIX_LOCAL_API_BASE + SIRIX_AI_SESSION_ID` 判断当前是否处于 Sirix 托管会话。
  - 新增 `effective_approval_policy_for_sirix()`：Sirix 托管会话中将旧 Codex `AskForApproval::Never` 视为“Sirix 负责审批”，避免旧策略提前拒绝。

- `third_party/codex-rs/core/src/exec_policy.rs`
  - Shell exec-policy prompt 在 Sirix 托管会话中不再经过 Codex legacy `AskForApproval::Never / Granular.*` 拒绝分支；请求必须先进入 Sirix 共享审批链路。

- `third_party/codex-rs/core/src/tools/runtimes/shell/unix_escalation.rs`
  - zsh fork / execve 拦截路径同样以 Sirix 作为审批权威，不再让 Codex legacy policy 在 Sirix 之前 deny。

- `third_party/codex-rs/core/src/tools/sandboxing.rs`
  - 默认审批需求、sandbox retry、approval bypass 判断统一先经过 `effective_approval_policy_for_sirix()`。

- `third_party/codex-rs/core/src/tools/handlers/mod.rs`
- `third_party/codex-rs/core/src/tools/handlers/shell.rs`
- `third_party/codex-rs/core/src/tools/handlers/unified_exec.rs`
  - `with_additional_permissions` / `require_escalated` 不再因为 Codex legacy `Never` 在 Sirix 托管会话中提前报错；应走 Sirix 审批。

- `third_party/codex-rs/core/src/tools/network_approval.rs`
  - 网络 allowlist miss 在 Sirix 托管会话中允许进入审批流，不再被 Codex `Never` 直接 hard-deny。

- `third_party/codex-rs/core/src/apply_patch.rs`
- `third_party/codex-rs/core/src/tools/runtimes/apply_patch.rs`
  - patch safety / retry 判断也统一使用 Sirix effective approval policy，避免 Codex legacy `Never` 与 Sirix 审批配置冲突。

### 原则

- Standalone Codex 行为保持不变：没有 Sirix 本地 API 环境变量时仍使用原 Codex policy。
- Sirix 托管会话中：旧 Codex policy 只作为兼容配置存在，不再是最终审批权威；所有可交互权限必须优先进入 Sirix 三端共享审批链路。

### 追加验证

- `cargo test -p codex-core sirix_shell_ask_can_prompt_even_when_codex_policy_is_never --manifest-path third_party/codex-rs/Cargo.toml`

## 2026-04-27 补充：Sirix CLI runtime logs

为方便排查 TUI 审批链路导致的异常退出 / crash，Sirix CLI 现在会在 Desktop 托管会话中把关键运行日志上报到 backend runtime logs：

- `third_party/codex-rs/tui/src/sirix_runtime_logger.rs`
  - 新增轻量 runtime logger，优先使用 `SIRIX_RUNTIME_LOGS_ENDPOINT`，否则通过 Desktop 注入的 `SIRIX_LOCAL_API_BASE` 上报到本地 `/runtime/logs`。
  - 日志 source 固定为 `sirix_cli`，backend 落盘为 `sirix-cli.log`。
  - 采用短延迟 + 周期 flush，避免每条日志阻塞 TUI，同时尽量在审批 crash 前把最近事件写出。
- `desktop-server/src/api/runtime.rs`
  - 新增本地 runtime log intake，只接受 `sirix_cli` source，并复用 Desktop Server 既有 `RuntimeLogger` 转发到 backend。
- `desktop-server/src/app/runtime_logger.rs`
  - RuntimeLogger 支持按 source 分组 flush，保留 `desktop_backend` 自身日志，同时可转发 CLI 外部日志。
- `backend-server/src/application/runtime_logging.rs`
  - 新增 `SirixCli` runtime log source，对应 `sirix-cli.log`。
- `third_party/codex-rs/tui/src/app.rs` 与 `third_party/codex-rs/tui/src/bottom_pane/approval_overlay.rs`
  - 新增 `[APPROVAL_TRACE]` 审批链路日志，覆盖 exec/apply_patch 审批请求生成、镜像到 Desktop、本地/远端审批结果、用户选择和 abort 等关键节点。

日志中会记录 `thread_id`、`approval_id`、决策、持久化 scope、prefix、是否涉及 network / additional permissions / execpolicy amendment，以及截断后的 `command_preview`。`command_preview` 只用于排查审批触发点，避免输出无限长命令。

## 2026-04-27 补充：current-terminal wrapper 异常退出上报

命令行直接执行 `sirix` 并复用当前终端时，Desktop Server 不是实际 TUI 子进程的直接父进程；直接父进程是 `desktop-server/src/bin/sirix.rs` 这个 wrapper。因此 wrapper 现在会在启动真实 AI runtime 前后补充 runtime log：

- 启动前记录 `[SIRIX_WRAPPER_RUNTIME] AI runtime starting`。
- `Command::status()` spawn 失败时记录 `[SIRIX_WRAPPER_RUNTIME] AI runtime spawn failed`，随后继续返回原 `anyhow::Error`，不吞掉错误。
- 子进程正常退出时记录 `[SIRIX_WRAPPER_RUNTIME] AI runtime exited successfully`。
- 子进程非 0 退出或 Unix signal 结束时记录 `[SIRIX_WRAPPER_RUNTIME] AI runtime exited abnormally`，包含 `exit_code`、`signal`、`terminal_id`、`ai_session_id`、`workspace_root`、`codex_home`，上报完成后继续 `bail!`，保持原有异常语义。

Rust 没有传统 exception；这里用 `Result` 传播 wrapper 自身错误，用子进程 `ExitStatus` / Unix `ExitStatusExt::signal()` 表达实际 runtime 的 crash/abnormal exit，从而达到“先上报，再按原错误路径退出”的效果。

## 2026-04-27 补充：Shell 双审批竞态与 stale UI 保护

### 问题

release 日志 `backend-server/deploy/runtime-logs/release/20260427-142113/sirix-cli.log` 显示同一个 shell approval 会先被镜像到 Desktop，再由 TUI/CLI 本地 overlay 继续保留一份可操作 UI。典型序列是：

1. `[APPROVAL_TRACE] mirror shell approval request to Desktop`
2. Desktop/CLI raw prompt resolve 后记录 `mirrored shell approval resolved`
3. TUI 向 Codex 提交 `submit Sirix exec approval decision`，命令已经继续执行
4. stale 的第二个 overlay 后续仍可被用户选择，并再次尝试 `sync_resolution=true`

这会造成两个问题：

- 用户感知上像“同一条 Shell 指令需要审批两次”，第一处 approve 后任务已经继续，第二处 deny 已经无法阻止命令。
- 第二处 stale overlay 再次调用 `/shell-approvals/resolve` 时，后端 pending 已经被第一处 resolution 消耗，错误沿 TUI event loop 冒泡，导致 sirix cli 异常退出；release 日志最后一条 `sync_resolution=true` 后 CLI websocket 随即断开，与这个路径一致。

### 修复

- `desktop-server/src/app/ai/approval.rs`
  - `ShellApprovalRegistry` 新增 `take_pending()` / `restore_pending()`。
  - Shell approval resolve 从“先读 pending、稍后 remove”改为“先原子 claim pending”。只有第一个审批端能拿到 pending request；后续 stale resolve 返回 conflict，不再可能提交第二个互相矛盾的 Codex `ExecApproval`。

- `desktop-server/src/api/ai.rs`
  - `resolve_shell_approval_inner()` 使用 `take_pending()` 作为唯一入口。
  - prefix 校验、持久化、backend sync 失败时恢复 pending；成功后才写入 resolved request 并广播 `ai.approval.resolved`。
  - 已被其它端处理的 shell approval 返回 `409 Conflict`，语义上表示 stale approval UI，而不是真实服务崩溃。

- `third_party/codex-rs/tui/src/sirix_local_api.rs`
  - `resolve_session_shell_approval()` 返回 `Resolved / AlreadyResolved`。
  - 对 `404 / 409` stale-claim 响应做非致命处理，避免 TUI 因 stale resolve 直接 crash。

- `third_party/codex-rs/tui/src/app.rs`
  - `sync_resolution=true` 发现 `AlreadyResolved` 时只记录 `[APPROVAL_TRACE] ignored stale Sirix exec approval decision` 并返回，不再提交第二个 Codex `ExecApproval`。
  - resolve 失败时记录 `[APPROVAL_TRACE] failed to sync Sirix exec approval decision` 并在 UI 中提示错误，不继续执行命令，也不让错误冒泡导致 CLI 退出。
  - 外部 Desktop/CLI raw prompt 赢得审批后，会调用 TUI bottom pane dismiss 逻辑移除本地 stale exec approval overlay。

- `third_party/codex-rs/tui/src/bottom_pane/bottom_pane_view.rs`
- `third_party/codex-rs/tui/src/bottom_pane/mod.rs`
- `third_party/codex-rs/tui/src/bottom_pane/approval_overlay.rs`
- `third_party/codex-rs/tui/src/chatwidget.rs`
  - 新增 `dismiss_exec_approval(thread_id, approval_id)` 链路。
  - 当其它审批端已经 resolve 同一 approval 时，当前/队列中的匹配 exec approval 会被移除，但不会发送新的 AppEvent，保证 Codex core 只收到一次最终审批结果。

### 验证

- `cargo check --manifest-path desktop-server/Cargo.toml --package desktop-server`
- `cargo check --manifest-path third_party/codex-rs/Cargo.toml -p codex-tui`
- `cargo test --manifest-path desktop-server/Cargo.toml --package desktop-server shell_registry -- --nocapture`
- `cargo test --manifest-path third_party/codex-rs/Cargo.toml -p codex-tui dismiss_exec_approval_advances_without_emitting_second_decision -- --nocapture`

上述验证均通过；输出中仍有项目既有 dead_code / unused warning。

## 2026-04-27 补充修正：Shell 合法两阶段审批与重复审批区分

### 语义澄清

Shell 审批里存在两类不同的审批门禁，不能混为“重复审批”：

1. **Shell capability 授权门禁**：确认当前 Agent 是否允许使用 `builtin.shell`，以及授权只对本次、当前 Session 等范围生效。
2. **Shell command / prefix 执行门禁**：确认本条具体命令是否执行；当用户选择 Session / Workspace / Global 持久化时，还必须再选择要记住的命令前缀。

只有同一个 `request_id` 的同一审批点被 Desktop / Mobile / CLI / TUI 多端重复点击时，后到的 stale decision 才应该被忽略。不同 `request_id` 即使同属 `builtin.shell`，也必须按队列依次完成，不能用 capability key 粗暴去重。

### 修复

- `third_party/codex-rs/core/src/tools/handlers/shell.rs`
  - Shell handler 在进入具体命令执行审批前，显式调用 Sirix `builtin.shell` capability approval gate。
  - 这样 Shell capability 授权通过后，仍会继续进入 command / prefix 审批；如果后者拒绝，命令不会执行。

- `desktop-server/src/api/ai.rs`
  - `/ai/sessions/approvals/resolve` 新增 `approval_kind` 语义。
  - `approval_kind = shell` 或 request_id 属于 `ShellApprovalRegistry` 时，走 shell command/prefix resolve；否则 `builtin.shell` 也可以作为普通 capability approval 走 `AiApprovalRegistry`。
  - 这避免 capability 授权和 command 审批因为共享 `capability_key = builtin.shell` 而被错误路由到同一个 registry。

- `desktop-server/src/cli_approval.rs`
- `desktop-server/src/cli_approval_display.rs`
  - raw CLI approval prompt 的去重身份改为 `request_id`，不再按 `session + agent + capability` 合并不同审批点。
  - raw CLI 对持久化 shell 选择改为两阶段状态机：先选择 allow/deny + scope，再进入 command prefix 选择；只有 prefix 也选择完成后才提交 resolve。
  - `approval_kind=shell` 才按 shell command 展示；普通 `builtin.shell` capability 授权按 capability 文案展示。

- `client/packages/feature_terminal/lib/src/terminal_view_model_events_b.dart`
- `client/packages/infra_api/lib/src/desktop_local_client.dart`
- `client/packages/infra_api/lib/src/http_backend_api_client.dart`
- `client/packages/infra_api/lib/src/backend_api_client.dart`
- `client/packages/infra_api/lib/src/mock_backend_api_client.dart`
  - Flutter resolve 请求透传 `approval_kind`。
  - pending approval 移除逻辑在存在 `request_id` 时只移除精确匹配项，不再因为同 capability key 删除其它合法等待中的审批。

### 验证

- `cargo test --manifest-path desktop-server/Cargo.toml --package desktop-server cli_approval -- --nocapture`
  - 覆盖同 capability 不同 request_id 必须排队、持久化 shell 选择必须进入 prefix 二阶段后才 resolve。
- `cargo check --manifest-path desktop-server/Cargo.toml --package desktop-server`
- `cargo check --manifest-path third_party/codex-rs/Cargo.toml -p codex-core`
- `cargo check --manifest-path third_party/codex-rs/Cargo.toml -p codex-tui`
- `flutter analyze packages/feature_terminal packages/infra_api`
  - 未发现本次改动引入的 Dart 类型错误；命令仍因项目既有 `invalid_use_of_protected_member` / `unnecessary_library_name` analyzer 项退出非 0。
- `git diff --check`

备注：本机 `dart format` 因 Dart SDK 在当前沙箱内触发 `runtime/vm/cpuinfo_macos.cc: unreachable code` 崩溃，未能完成 Dart 格式化；相关 Dart 改动保持手工格式一致。
