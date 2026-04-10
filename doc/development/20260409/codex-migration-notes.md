# Sirix 中迁移/借鉴的 Codex 可靠性方案说明

本文记录当前 Sirix AI/CLI 实现中，哪些设计和代码逻辑参考或迁移自 Codex，以及迁移目的。

## 1. 已迁移/借鉴的能力

### 1.1 多层配置与工作区 fallback

借鉴点：

- 全局主配置目录集中到 `~/.sirix/`
- 工作区优先读 `.sirix/config.toml`
- 缺失时回退 `.codex/config.toml`
- 启动时将历史 `~/.codex` 结构迁移到 `~/.sirix`

迁移目的：

- 保持与 Codex 用户习惯一致
- 降低已有工作区和用户配置的迁移成本
- 避免多配置源并存导致的不确定行为

Sirix 适配说明：

- Sirix 额外要求由 `desktop-server` 统一管理配置读写，因此配置不由 CLI 直接写盘，而由本地 API 统一写入。

### 1.2 CLI 通过 bridge config 驱动运行时

借鉴点：

- 为每个 AI session 生成独立运行时目录
- 按会话生成 bridge 配置，注入 model/provider/instructions/sandbox/MCP/skills
- 使用独立 `codex-home` 目录隔离 session 级运行状态

迁移目的：

- 降低不同 AI session 相互污染的风险
- 保持运行期配置可追踪、可复现
- 避免多个会话共享临时状态造成不稳定

Sirix 适配说明：

- 会话由 Sirix 的 `ai_session_id` 管理，并映射到独立的 terminal session。

### 1.3 本地 daemon + CLI 分层

借鉴点：

- CLI 作为交互前端
- 配置、状态与生命周期由长期运行的本地服务管理

迁移目的：

- 提高恢复能力和可观测性
- 让普通 Terminal、Desktop App、Mobile App 可以共享同一会话视图

Sirix 适配说明：

- 这里不是直接复用 Codex 的 app-server，而是由 `desktop-server` 充当本机控制平面。

### 1.4 MCP server 过滤与 transport 防御式校验

借鉴点：

- MCP server 按 transport 处理
- 支持 server 级 tool enable/disable
- 配置加载前做结构化校验，而不是等运行时报错

迁移目的：

- 提前拦截错误配置，避免会话启动后才失败
- 减少不受控 MCP server 进入 agent 运行环境

Sirix 当前落地：

- 支持 `stdio/http` 总开关
- 保存前校验 MCP 配置是否能推断出 transport
- 校验 `command/cmd`、`url/endpoint`
- 校验 `enabled_tools/disabled_tools` 不冲突

### 1.5 Skills 目录化加载约束

借鉴点：

- skill 以目录为单位管理
- 以 `SKILL.md` 作为最小有效入口

迁移目的：

- 保证 skills 可被稳定发现和解析
- 避免“只选了一个目录但没有 skill 定义”的脏配置

Sirix 当前落地：

- 导入 skill 文件夹和保存设置时都会校验 `SKILL.md`
- 支持全局 skills 和工作区 skills

### 1.6 审批模型与作用域缓存

借鉴点：

- 审批不是一次性 UI 动作，而是运行时策略的一部分
- 审批结果需要区分作用域

迁移目的：

- 降低重复弹窗
- 避免授权状态在一个会话内丢失
- 提升交互可预测性

Sirix 当前落地：

- `once / session / deny` 三种作用域
- 本地实时审批弹窗
- 本地审批缓存持久化到 `~/.sirix/runtime/approvals/`
- backend 审计镜像写入 `ai_session_approvals`

### 1.7 终端输出回放与批量刷新

借鉴点：

- 终端流不是逐字节同步，而是做小批量 flush 和 replay buffer
- attach 时回放最近输出快照

迁移目的：

- 降低多端同步抖动
- 避免 attach 后看不到前文
- 提高高频输出时的稳定性

Sirix 当前落地：

- `desktop-server` terminal manager 已按批量输出和 replay buffer 广播本地/远端终端流

## 2. 没有直接迁移、而是按 Sirix 重写的部分

- AI session 和 terminal session 的建模：Sirix 明确拆分为独立实体，再通过映射关联。
- 设置中心：由 `desktop-server` 提供本地配置 API，Desktop App 负责 UI。
- 多端同步链路：继续复用 Sirix 自己的 terminal / backend / mobile 事件体系。
- 授权 UI：采用 Sirix 的桌面终端页弹窗卡片，而不是复用 Codex TUI 审批界面。

## 3. 迁移原则

本次迁移不是“把 Codex 当黑盒嵌入 Sirix”，而是遵循以下原则选择性迁移：

- 迁移能明显提升可靠性、稳定性、安全性、健壮性的逻辑
- 保留 Sirix 自己的 session、terminal、多端同步与设置架构
- 优先迁移配置、校验、隔离、缓存、回放这类基础设施能力
- 避免直接引入与 Sirix 现有链路冲突的 TUI/app-server 假设
