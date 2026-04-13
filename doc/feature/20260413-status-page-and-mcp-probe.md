# Status 页与 MCP 启动探测

## 功能说明

本次新增了独立的 Status 页，用于替代原来的独立 Terminal 页导航位置。Dashboard 中的 Terminal 工作区保留不变，但 standalone Terminal 入口被标记为 Deprecated，并从主导航中隐藏。

Status 页当前主要提供以下状态：

- Backend 连接状态
- desktop-server runtime 状态
- AI Session 数量
- Local Terminal 数量
- MCP 状态

其中 MCP 状态以标签形式展示：`MCP Title + 颜色小圆点`

- 绿色：desktop-server 启动后的 MCP 探测成功
- 红色：MCP 探测失败或配置异常

同时，为了避免 MCP 完全等到 Sirix CLI / app-server 会话启动后才有状态，本次把 MCP 状态探测前移到了 `desktop-server` 启动后的后台任务中。

## 代码位置

### 1. desktop-server 状态采集与 API

- `desktop-server/src/app/status.rs`
  - 新增状态注册表
  - 新增 MCP 探测逻辑
  - 生成状态总览响应
- `desktop-server/src/app/state.rs`
  - AppState 增加 status_registry
- `desktop-server/src/app/tasks.rs`
  - 新增后台 MCP 周期探测任务
- `desktop-server/src/api/status.rs`
  - 新增 `/status/overview`
- `desktop-server/src/api/mod.rs`
  - 注册状态接口路由

### 2. MCP 配置探测辅助

- `desktop-server/src/app/ai/config.rs`
  - 新增 `McpProbeTarget`
  - 新增 MCP 探测目标提取逻辑
  - 统一从 MCP 配置中提取 `stdio command/args/env` 或 `http url`

### 3. Flutter Status 页

- `client/packages/infra_api/lib/src/models.dart`
  - 新增本地状态总览模型
- `client/packages/infra_api/lib/src/desktop_local_client.dart`
  - 新增 `getStatusOverview()`
- `client/packages/feature_terminal/lib/src/status_page.dart`
  - 新增 Status 页
- `client/apps/desktop_app/lib/main.dart`
- `client/apps/mobile_app/lib/main.dart`
- `client/lib/src/shell/desktop_shell_page.dart`
- `client/lib/src/shell/mobile_shell_page.dart`
  - 用 Status 页替代原 standalone Terminal 导航位置

## 实现方法

### 1. 为什么原本不会马上 Starting MCP Server

当前 Sirix 的 MCP 连接建立本质上还是跟随 `codex` / app-server 的会话生命周期。在没有实际 AI Session 或没有触发相关刷新逻辑时，MCP 不一定会在 Sirix 刚启动时就建立连接，因此会出现“之前看起来会立刻 Starting MCP Server，现在没有”的体感差异。

本次没有把 desktop-server 直接改成长期托管完整 MCP 连接，而是先实现一个更稳定的前置探测层：

- desktop-server 启动后立即开始后台 MCP probe
- 周期性刷新 probe 结果
- Status 页直接消费 probe 状态

这样能先解决“启动后完全没有 MCP 状态可见性”的问题，同时避免把 desktop-server 直接耦合成完整的 MCP 会话宿主。

### 2. MCP probe 的当前策略

按 transport 分两类探测：

- `stdio`
  - 尝试根据配置启动对应命令
  - 短时间内没有异常退出则视为探测成功
- `http`
  - 尝试访问配置中的 MCP URL
  - 2xx / 401 / 403 / 405 视为可达

这代表的是“desktop-server 启动阶段可用性探测”，不是完整的长期 MCP 会话连接托管。

### 3. 为什么用 Status 替换 standalone Terminal

Dashboard 本身已经包含 terminal 工作区，继续保留单独 Terminal 导航会造成信息重复和入口分散。因此本次调整为：

- Dashboard 保留 Terminal 主工作区
- standalone Terminal 页从主导航移除
- Status 页占用原位置
- 在 Status 页内明确标记 standalone Terminal 已 Deprecated

这样导航信息密度更合理，也为后续继续加入 backend / device / MCP / AI runtime 状态留出统一承载入口。
