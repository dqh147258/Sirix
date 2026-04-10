# Sirix AI Agent / CLI 整体实现方案

## 1. 目标

在 Sirix 现有 `desktop-server + backend-server + Flutter Desktop/Mobile` 架构上，落地一套类似 Codex 的本地 AI 编程工具体系，满足以下目标：

- 提供 `sirix` CLI 指令，具备类似 Codex 的交互式编程工具体验。
- 支持沙箱、内置工具、MCP、Skills、多 Agent、Plan、Shell、文件读写等核心能力。
- 不论从普通 Terminal 还是 Sirix App 内置 Terminal 启动，CLI 效果都能在 Desktop App / Mobile App 中同步展示。
- 支持多个并发 CLI/Agent 实例。
- 支持全局配置与工作区配置，工作区优先 `.sirix`，并兼容 `.codex`。
- 提供 Desktop App 设置页，配置能力由 `desktop-server` 提供，Flutter 仅负责 UI。

## 2. 当前仓库现状

### 2.1 已有可复用基础

- `desktop-server` 已具备：
  - 本地 HTTP/WS 服务
  - 本地鉴权会话持久化
  - PTY Terminal 管理
  - backend 事件订阅
  - 本地 Flutter Desktop 通信
- `backend-server` 已具备：
  - 用户/设备/会话体系
  - desktop/mobile 事件总线
  - terminal session 元数据与输出中继
- Flutter 已具备：
  - `feature_terminal`，基于 `xterm` 渲染终端
  - Desktop / Mobile 两端共享 Terminal 页面和同步链路
  - Desktop 现有右上角头像区域，但还没有设置页与完整导航路由

### 2.2 当前缺口

- 已有 AI 基础骨架，但仍缺完整 agent runtime（工具调度、plan、审批流）与稳定性闭环。
- `sirix` CLI 与启动链路已落地第一版，但命令集与错误恢复能力仍需扩展。
- 沙箱仍主要依赖 Codex 侧能力，Sirix 自身的跨平台沙箱策略抽象未完整实现。
- `desktop-server` 已有 `/ai/config` 与 `/ai/sessions`，Desktop 设置页与配置读写已完成，但 AI runtime 更深层的 tool orchestration 仍需继续拆分。
- Provider / Model / Agent / Skills / MCP 已有配置结构、可视化编辑、导入与保存前校验；后续重点是扩充 runtime 能力和更强的沙箱策略。
- AI 会话已拆出独立 `ai_sessions` 元数据体系，并与 terminal session 通过映射关联。

## 3. Codex 参考实现结论

本地参考仓库 `/Volumes/MacData/Data/DownloadCode/codex` 显示，Codex 的成熟能力主要分成几层：

- CLI/TUI 启动层
- 配置层
  - 全局 `~/.codex/config.toml`
  - 项目 `.codex/config.toml`
  - 多层 config merge
- 沙箱层
  - macOS seatbelt
  - Linux seccomp/landlock/bwrap
  - Windows restricted token
- MCP 管理层
  - server transport
  - tool enable/disable
  - per-tool approval
- Skills 层
  - 系统 skills + 用户 skills
  - 文件监听与缓存
- Agent/Thread 层
  - 会话上下文
  - tool 调度
  - rollout / turn / plan

结论：

- Codex 的 Rust 模块化拆分是可以直接借鉴的。
- 但 Sirix 不能把 Codex 当成一个单独黑盒 CLI 直接嵌进去，因为 Sirix 还要求：
  - 多端同步展示
  - 由 `desktop-server` 承担配置核心能力
  - 与现有 terminal / backend / mobile 链路融合
- 因此更合理的路线是：
  - 复用 Codex 的核心 Rust 设计与部分实现
  - 在 Sirix 内重新组织为“本地 daemon + CLI 前端 + 多端镜像 + 设置中心”

## 4. 推荐总体架构

## 4.1 架构原则

- `sirix` 不是单纯本地 CLI，而是 `desktop-server` 管理下的 AI session 客户端。
- `desktop-server` 作为本机 AI 控制平面与配置中心。
- `backend-server` 继续承担跨端同步、鉴权、远程订阅与移动端分发。
- Flutter Desktop/Mobile 继续复用终端渲染能力，避免为 AI CLI 再造一套展示协议。

## 4.2 模块划分

建议新增一组 AI 模块，优先放在 `desktop-server` 内部做第一阶段集成（当前已部分落地）：

- `desktop-server/src/app/ai/config.rs`（已落地）
  - 全局配置、工作区配置、`.sirix/.codex` 兼容加载、持久化写入
- `desktop-server/src/app/ai/provider/`（待拆分）
  - Provider / Model 注册、能力抽象、凭证读取
- `desktop-server/src/app/ai/agent/`（待拆分）
  - Agent profile、系统提示词、工具开关、权限策略
- `desktop-server/src/app/ai/mcp/`（待拆分）
  - MCP server 生命周期、配置、工具过滤、审批策略
- `desktop-server/src/app/ai/skills/`（待拆分）
  - 全局与工作区 Skills 管理、导入、启用状态、越沙盒标记
- `desktop-server/src/app/ai/sandbox/`（待拆分）
  - 平台沙箱封装
- `desktop-server/src/app/ai/session.rs`（已落地）
  - AI session registry、attach/detach、镜像广播、实例管理
- `desktop-server/src/app/ai/runtime/`（待拆分）
  - Agent 执行器、turn orchestration、plan/tool 调度
- `desktop-server/src/app/ai/cli_bridge/`（待拆分）
  - `sirix` CLI 与 daemon 的本地 RPC/stream 协议

同时新增一个 CLI 二进制：

- `desktop-server/src/bin/sirix.rs`

这样可以先避免把仓库改造成新的 Rust workspace，大幅降低第一次落地复杂度。

## 4.3 运行时关系

### 4.3.1 普通 Terminal 启动

1. 用户在任意终端执行 `sirix`
2. `sirix` 连接本机 `desktop-server`
3. `desktop-server` 创建一个 `ai_session`
4. CLI 当前终端作为主交互端
5. `desktop-server` 将该 session 的屏幕输出流同步给：
   - 当前 CLI
   - Desktop App Terminal
   - Mobile App Terminal

### 4.3.2 Sirix App Terminal 启动

1. 用户在 Sirix App 的 Terminal 中执行 `sirix`
2. 该命令同样连接 `desktop-server`
3. 创建或附着到一个新的 `ai_session`
4. 输出继续通过现有 terminal/stream 展示

### 4.3.3 多实例

- 每次 `sirix` 启动生成独立 `ai_session_id`
- session 具备：
  - 发起端
  - 工作目录
  - agent profile
  - 当前 attached participants
  - mirror viewers

## 5. 为什么不建议直接把 AI CLI 建成“普通 shell 子进程”

如果把 `sirix` 仅仅当成一个本地 TUI 子进程，虽然本地可运行，但会有三个问题：

- 普通 Terminal 中启动时，Sirix App 无法天然知道该会话存在。
- 配置、审批、Agent 列表、MCP/Skills 控制会分散在 CLI 与 App 两端。
- 多端 attach / session 管理 / 权限审计会变得混乱。

所以更稳妥的方式是：

- `sirix` CLI 负责“交互前端”
- `desktop-server` 负责“session 控制平面与配置平面”

## 6. 配置设计

## 6.1 配置来源与优先级

建议采用与 Codex 接近但按 Sirix 需求调整后的层次：

1. 内置默认值
2. 全局配置 `~/.sirix/config.toml`
3. 工作区配置：
   - `${workspace}/.sirix/config.toml`
   - 若 `.sirix` 不存在，则回退 `${workspace}/.codex/config.toml`
4. 会话级 runtime overrides

目录建议：

```text
~/.sirix/
  config.toml
  skills/
  state/
  logs/
  secrets/

${workspace}/.sirix/
  config.toml
  skills/
  mcp/
```

## 6.2 配置模型

建议统一使用 TOML 作为主配置格式，原因：

- 与 Codex 兼容成本最低
- 适合多层 merge
- 工作区配置更自然

但 Desktop App 与 `desktop-server` 间可使用 JSON API 传输，最终由 `desktop-server` 负责读写 TOML。

## 6.3 配置主实体

建议抽象以下对象：

- `CliSettings`
  - 全局补充系统提示词
- `ProviderConfig`
  - 类型
  - endpoint / auth / extra headers
  - enabled
- `ModelConfig`
  - provider_id
  - model_id
  - display_name
  - model_kind
  - context_window
  - supports_image
  - supports_tools
  - supports_reasoning
- `SkillConfig`
  - name
  - path
  - enabled
  - allow_outside_sandbox
- `McpServerConfig`
  - name
  - transport config
  - enabled
  - default outside sandbox
  - tool-level toggles
  - approval mode
- `AgentProfile`
  - name
  - model_ref
  - system_prompt
  - enabled built-in tools
  - skill allow/deny rules
  - MCP allow/deny rules
  - per-capability approval mode

同时预埋模型类型枚举：

- `text`
- `image_generation`
- `asr`
- `tts`
- `embedding`

## 7. 沙箱设计

## 7.1 推荐方案

优先借鉴 Codex 的平台能力：

- macOS: Seatbelt
- Linux: Landlock / seccomp 风格封装
- Windows: 先预留接口，后补实现

Sirix 当前阶段最重要的是把抽象先建立起来，而不是一次性做完所有平台特性。

## 7.2 Sirix 沙箱抽象

建议抽象：

- `SandboxMode`
  - `danger_full_access`
  - `workspace_write`
  - `read_only`
- `SandboxPolicy`
  - writable roots
  - readable roots
  - network access
  - inherit env white list
- `SandboxBypassRule`
  - skill path
  - mcp tool
  - built-in tool

## 7.3 与 Skills / MCP 的关系

- MCP 默认不受沙箱限制
- Skill 默认受沙箱限制
- 但 Skill 可配置 `allow_outside_sandbox = true`
- Agent 调用工具前，统一走权限决策器：
  - 全局规则
  - workspace 规则
  - agent profile 规则
  - 本次会话授权状态

## 8. Agent 设计

## 8.1 Agent Profile

每个 Agent 应可独立配置：

- 模型
- 系统提示词
- 内置工具开关
- Skills 开关
- MCP 开关
- 审批策略

建议区分三层能力：

- Builtin tools
- Skills
- MCP tools

每层均支持：

- 默认继承全局
- 显式禁用
- 单项精细化覆盖

## 8.2 多 Agent

建议支持两类：

- 主 Agent
- 子 Agent / worker Agent

第一阶段只要把数据模型、配置、运行时 session 隔离设计好，就能后续逐步补全真正的 sub-agent 调度。

## 9. CLI 设计

## 9.1 命令定位

`sirix` 建议支持：

- 交互式默认模式
- `sirix exec ...`
- `sirix app`
- `sirix config ...`
- `sirix mcp ...`
- `sirix agent ...`

但第一阶段建议只做：

- `sirix`
- `sirix resume <session-id>`
- `sirix list`

## 9.2 CLI 与 desktop-server 通信

当前已复用本地 `/ws` 的 terminal 事件协议，短期可行；后续可按复杂度再拆 AI 专用 WS。

当前已落地本地 AI 接口：

- `GET /ai/config`
- `PATCH /ai/config`
- `GET /ai/config/effective`
- `GET /ai/sessions`
- `POST /ai/sessions`

后续建议补齐（按需要）：

- `POST /ai/sessions/:id/attach`
- `POST /ai/sessions/:id/approve`
- `POST /ai/sessions/:id/close`

本地 transport 建议：

- 控制面：HTTP JSON
- 数据面：WS

这样 Flutter Desktop、CLI、后续桌面宿主都能复用。

## 10. AI Session 与终端镜像设计

## 10.1 新增 session 类型

建议不要把 AI CLI 与普通 PTY terminal session 完全混成同一个模型，而是扩展为：

- `session_kind = terminal | ai_cli`

原因：

- AI CLI 需要保存 agent/config/model/approval/runtime metadata
- 普通 PTY 只关心 shell 与输出流

## 10.2 数据模型建议

`backend-server` 建议新增：

- `ai_sessions`
  - `id`
  - `device_id`
  - `creator_user_id`
  - `workspace_root`
  - `agent_id`
  - `model_id`
  - `status`
  - `entrypoint`
  - `created_at`
  - `updated_at`
  - `closed_at`
- `ai_session_participants`
  - `session_id`
  - `participant_type` (`cli|desktop_app|mobile_app`)
  - `client_instance_id`
  - `joined_at`
- `ai_session_approvals`
  - `session_id`
  - `capability_key`
  - `decision`
  - `scope` (`once|session|deny`)
  - `created_at`

如果想尽量减少 schema 数量，也可以先复用 `terminal_sessions`，但长期维护上不建议。

## 10.3 流协议

建议 AI session 数据面延续 terminal 思路：

- `ai.session.ready`
- `ai.session.output`
- `ai.session.snapshot`
- `ai.session.status`
- `ai.session.closed`
- `ai.session.error`
- `ai.session.approval.request`
- `ai.session.approval.resolved`

这里的 `output` 仍建议保留 base64 字节流，这样普通终端渲染和 TUI 渲染都统一。

## 11. MCP / Skills 设计

## 11.1 Skills

建议保持 Codex 风格：

- 目录导入
- 识别 `SKILL.md`
- 支持系统 skills、用户全局 skills、工作区 skills

Sirix 额外规则：

- skill 记录显式的 `allow_outside_sandbox`
- UI 层支持启用/禁用与导入

## 11.2 MCP

建议兼容 Codex 的 MCP 配置思想：

- stdio transport
- http transport
- enabled / required / tool filters
- tool-level approval

Sirix 的新增点：

- 全局 MCP 总开关
- 分 server 开关
- 分 tool 开关
- Agent 级 override

## 12. Desktop App 设置页设计

## 12.1 入口

当前 `client/apps/desktop_app/lib/main.dart` 右上角头像只是静态圆形容器，没有菜单行为。

建议修改为：

- 点击头像弹出 `ContextMenu` / `PopupMenuButton`
- 菜单项至少包含：
  - `Settings`
  - `Logout`

## 12.2 页面结构

设置页建议采用左侧分组导航 + 右侧详情面板，沿用当前深色工业风与 `SirixTheme`：

- `CLI`
- `Providers & Models`
- `Skills`
- `MCP`
- `Agents`

建议新建 feature：

- `client/packages/feature_settings_ai/`

内部拆分：

- `settings_page.dart`
- `settings_view_model.dart`
- `settings_state.dart`
- `sections/cli_settings_section.dart`
- `sections/provider_settings_section.dart`
- `sections/skills_settings_section.dart`
- `sections/mcp_settings_section.dart`
- `sections/agent_settings_section.dart`

## 12.3 数据交互

Desktop App 仅做 UI，不直接写磁盘。

所有配置读写均通过 `desktop-server`：

- Desktop Flutter -> local HTTP/WS
- `desktop-server` -> 读写 `~/.sirix/config.toml`

## 13. 后端改造范围

## 13.1 desktop-server

这是本次改造的主战场。

需要新增：

- AI 配置存储与 merge loader
- AI session registry
- CLI attach protocol
- Approval service
- MCP / Skills / Agent config service
- 本地 API
- backend 同步

## 13.2 backend-server

需要新增：

- AI session 元数据表
- AI session 事件总线
- mobile/desktop attach 能力
- AI session 输出中继

## 13.3 Flutter client

需要新增：

- Desktop 设置页
- AI session 列表/attach 展示
- 复用或扩展 `feature_terminal`

## 14. 当前实施进度（截至 2026-04-09）

## 14.1 已完成

- `desktop-server` 已新增 `app::ai` 基础模块：
  - `src/app/ai/config.rs`
  - `src/app/ai/session.rs`
- 全局配置已切到 `~/.sirix/config.toml`，并落地目录初始化：
  - `~/.sirix/runtime/sessions`
  - `~/.sirix/skills`
  - `~/.sirix/secrets`
- 已支持旧 `~/.codex` 迁移到 `~/.sirix`。
- 工作区配置已实现文件级 fallback：
  - 优先 `${workspace}/.sirix/config.toml`
  - 缺失时回退 `${workspace}/.codex/config.toml`
- 本地 AI 配置与会话 API 已落地：
  - `GET/PATCH /ai/config`
  - `GET /ai/config/effective`
  - `GET/POST /ai/sessions`
- `sirix` CLI 第一版已落地（`desktop-server/src/bin/sirix.rs`）：
  - `sirix`
  - `sirix list`
  - `sirix resume <terminal_id>`
- `sirix` 已支持自动拉起 `desktop-server`。
- 未登录时已支持交互提示登录，取消后仍可继续本机使用。
- Terminal 侧已注入 `SIRIX_HOME` 和 `~/.sirix/bin` 到运行环境，支持命令调用一致性。
- backend 已新增本机桌面 terminal 注册入口：
  - `POST /api/v1/desktop/terminals/local`
- Flutter `infra_api` 已新增 AI 配置数据模型与本地 API 客户端调用。
- backend 已新增独立 AI session 元数据能力：
  - `ai_sessions / ai_session_participants / ai_session_approvals` 表
  - `POST /api/v1/desktop/ai-sessions/local`
  - `GET /api/v1/ai-sessions`
- `desktop-server` 已改为 AI session 与 terminal session 独立建模：
  - AI 会话主标识：`ai_session_id`
  - 终端展示通道：`terminal_id`
  - 通过 `ai_session.terminal_id` 关联
- Desktop App 已落地 Avatar 菜单 `Settings/Logout` 与 AI Settings 页面，支持 CLI/Provider/Skills/MCP/Agent 配置编辑与保存。

## 14.2 进行中

- AI 会话对外仍通过 terminal 协议镜像（独立 `ai_session` 已建模，展示与交互继续复用 terminal 流）。
- 授权 API 与审计链路已落地，实时弹窗交互可作为后续增强项。

## 14.3 未完成

- Sirix 自有沙箱策略抽象（跨平台）可继续增强，目前以 Codex 运行时沙箱能力为主。

## 15. 已确认决策（来自需求文档问答）

以下决策已确认，不再作为“待确认项”：

1. 当 `desktop-server` 未运行时，`sirix` 必须自动拉起（已实现）。
2. Mobile App 对外部 Terminal 启动的 `sirix` 会话，需要支持交互输入（不是只读）。
3. 未登录允许单机运行；但要提示“是否登录”，默认确认，取消后继续可用（CLI 已实现提示流程）。
4. 全局配置使用 `~/.sirix/config.toml`，并迁移历史配置到 `~/.sirix/`（已实现）。
5. `.sirix/.codex` 兼容按文件级 fallback 处理（已实现）。
6. Provider 密钥第一阶段写入 `~/.sirix/` 管理域（目录已建立，后续补加密与权限控制）。
7. 授权粒度按全量能力设计：内置工具级、MCP server 级、MCP tool 级、Skill 级、Shell 命令级。

## 16. 继续执行清单（直到任务闭环）

主链路已闭环完成。后续建议按优先级继续增强：

1. 授权交互体验增强：将 `check/resolve approval` 接到会话内实时弹层与操作流。
2. 沙箱能力增强：补齐 Sirix 自有跨平台策略层与更细粒度策略下发。
3. 测试体系增强：补齐单测/集成/UI 自动化回归。

## 17. 测试策略

建议至少补三层测试：

- Rust 单元测试
  - config merge
  - `.sirix/.codex` fallback
  - agent policy resolution
  - sandbox policy generation
- 集成测试
  - desktop-server 本地 API
  - CLI attach / detach
  - backend relay
- Flutter 桌面 UI 测试
  - Settings sections
  - 表单状态与响应式布局

## 18. 风险与关键判断

### 18.1 最大风险

- 直接照搬 Codex 全仓会带来过大的依赖面和维护成本。
- 若不先建立 `desktop-server` 作为 AI 控制平面，后续 App 同步与设置中心会反复返工。
- 若把 AI session 与普通 terminal session 混成同一实体，后续 Agent / approval / audit 会越来越乱，且难以满足独立授权与审计要求。

### 18.2 本方案取舍

- AI session 与 terminal session 强制独立建模，二者通过 `ai_session.terminal_id` 关联。
- CLI 使用 AI session 作为主标识；内置 Terminal 继续通过已有关联 terminal 流展示输入输出。
- 先保证架构方向、数据模型、会话链路和配置层正确，再逐步补齐 Codex 级细节。
- 已落地部分继续沿当前实现演进，不回退、不推倒重来。
