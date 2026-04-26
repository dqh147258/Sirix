# SubAgent 模型继承收口与上下文窗口切换保护

## 功能说明

本次改动把两条原本容易产生误判的运行时路径收口成一致行为：

- `spawn_agent` 不再向模型暴露可直接覆盖 child model 或 child reasoning effort 的参数，SubAgent 默认继承当前会话/角色已经解析完成的模型；推理档位由目标模型自身能力与 CLI 模型设置决定。
- Sirix 本地 Agent 切换与 TUI `/model` 切换都会先检查“当前上下文 token 使用量是否已经超过目标模型的有效上下文窗口”，超出时直接阻断切换，并给出明确错误提示。

这样可以避免两类问题：

1. 模型在多 Agent 工具描述里暴露过多可选项，导致子 Agent 绕过当前会话/角色模型约束。
2. 用户在上下文已经很大的时候切到更小窗口模型，表面切换成功，但随后在真实请求阶段才失败。

## 代码位置

- `third_party/codex-rs/tools/src/agent_tool.rs`
  - 移除 `spawn_agent` 的 `model` 参数 schema 与 picker-visible model 描述。
  - 移除 `spawn_agent` 的 `reasoning_effort` 参数 schema，避免调度 Agent 给不支持推理档位的 Provider/模型传入无效覆盖。
- `third_party/codex-rs/core/src/tools/handlers/multi_agents_common.rs`
  - 删除 SubAgent model override 逻辑。
  - 改为忽略旧提示词中残留的 `reasoning_effort` override；如果继承或角色配置带来的推理档位不被目标模型支持，则清空并回退到目标模型默认行为，而不是中断调度。
- `third_party/codex-rs/core/src/tools/handlers/multi_agents/spawn.rs`
- `third_party/codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs`
  - `spawn_agent` 参数结构删除 `model`，并对旧上下文可能传入的 `reasoning_effort` 做兼容忽略。
  - Begin / End 事件统一记录“最终生效”的模型与推理强度，而不是记录请求侧想覆盖的值。
- `third_party/codex-rs/protocol/src/openai_models.rs`
  - `ModelPreset` 增加 `effective_context_window`，把模型原始窗口与运行时 headroom 收口为一个可直接消费的字段。
- `third_party/codex-rs/tui/src/chatwidget.rs`
- `third_party/codex-rs/tui/src/app.rs`
- `third_party/codex-rs/tui/src/app_event.rs`
- `third_party/codex-rs/tui/src/sirix_local_api.rs`
  - `/model`、reasoning popup、Plan mode reasoning scope、Sirix `/agent` 切换都会先做上下文窗口预检。
  - 成功切换后立即刷新当前 runtime context window 显示。
  - Sirix `/agent` 切换会显式清空旧 reasoning，避免把前一个 Agent 的 effort 残留到新模型上。
- `third_party/codex-rs/app-server-protocol/src/protocol/v2.rs`
- `third_party/codex-rs/app-server/src/models.rs`
- `third_party/codex-rs/tui/src/app_server_session.rs`
  - app-server `model/list` 增加 `effective_context_window`，让 app-server-backed TUI 也能拿到切模预检所需的目标窗口元数据。
- `desktop-server/src/app/ai/config.rs`
  - 新增 `effective_model_runtime_context_window(...)`，统一把运行时窗口按 95% headroom 暴露给前端和 session runtime。
- `desktop-server/src/app/ai/session.rs`
  - session runtime 持久化 `effective_context_window`。
  - 新增 `validate_agent_context_window_switch(...)`，在 agent 切换时拒绝超窗切换。
- `desktop-server/src/api/ai.rs`
  - agent 列表与切换接口返回 `effective_context_window`。
  - agent 切换请求新增 `current_tokens_in_context`，服务端做二次防御校验。
  - 缺少 `current_tokens_in_context` 的 agent 切换请求会直接拒绝，避免“空 token 值”绕过切换保护。

## 实现方法

### 1. SubAgent 只继承模型，不再接受模型直改

以前 `spawn_agent` 允许请求侧直接带 `model`，这会让 child thread 最终使用的模型来源变成：

- 会话默认模型
- role 锁定模型
- 请求侧直接覆盖模型

三者并存时很难判断“哪个才是最终真值”。这次改成：

- child model 只来自当前线程继承值，或 role config 的显式锁定值
- 请求侧不能覆盖 `model` 或 `reasoning_effort`
- 若 role config 同时锁定 model / reasoning，则 role 仍然是最终优先级
- role 变更后的最终模型会重新用于 reasoning 兼容性收口；不支持时清空推理档位，避免先按父模型继承、再切到子模型导致的能力错配

这样 `spawn_agent` 的输入面更小，Begin / End 事件和 thread snapshot 也都只会反映最终生效配置。

### 2. 统一“有效上下文窗口”口径

Sirix 配置中的 `context_window` 是原始窗口，不等于 runtime 真正安全可切换的窗口。

这次统一新增 `effective_context_window`：

- 对桌面端 session runtime：由 `effective_model_runtime_context_window(...)` 生成
- 对 vendored Codex TUI model catalog：通过 `ModelPreset.effective_context_window` 透传

当前实现使用 95% headroom，给 system prompt、tool schema、输出等 runtime 开销预留空间，避免把原始配置窗口错误地当作“当前还能安全切换进去的窗口”。

### 3. TUI 与服务端双层拦截

切换保护分两层：

1. TUI 本地预检
   - 当前 `ChatWidget.token_info` 能拿到上下文 token 时，先在 UI 层阻断，避免无效请求发出。
2. desktop-server 服务端校验
   - `switch_session_agent` 请求会带上 `current_tokens_in_context`
   - `validate_agent_context_window_switch(...)` 再做一次防御
   - 若客户端拿不到当前 token 计数，则本次切换直接拒绝，而不是按 0 放行

这样无论是本地 `/model` 还是 Sirix `/agent`，都能在切换前就给出一致、可解释的失败原因；app-server 模型列表也会把窗口元数据透传到 TUI，避免只有 Sirix inline agent picker 才能做预检。

## 测试

- `third_party/codex-rs/tools/src/agent_tool_tests.rs`
  - 校验 `spawn_agent` schema 不再暴露 `model` / `reasoning_effort`。
- `third_party/codex-rs/core/tests/suite/spawn_agent_description.rs`
- `third_party/codex-rs/core/tests/suite/subagent_notifications.rs`
  - 校验工具描述不再列模型。
- `third_party/codex-rs/core/src/tools/handlers/multi_agents_tests.rs`
  - 校验旧上下文传入 `reasoning_effort` 时不会让不支持推理档位的模型调度失败，而是清空并回退到默认行为。
- `third_party/codex-rs/tui/src/chatwidget/tests/status_and_layout.rs`
  - 校验 runtime context window 会优先驱动状态栏展示。
  - 校验超出目标有效窗口时会生成阻断提示。
- `desktop-server/src/app/ai/config.rs`
- `desktop-server/src/app/ai/session.rs`
  - 新增 headroom 计算与 agent 切换窗口校验的单元测试。
