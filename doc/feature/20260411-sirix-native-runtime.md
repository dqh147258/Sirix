# Sirix Native Runtime / Provider Compatibility

## 本次功能

本次提交将 Sirix CLI 从“启动外部 Codex CLI”推进为“由 Sirix 自己管理并编译的本地 runtime 链路”。

当前实现重点包括：

- 将 Sirix CLI 运行时依赖的 Rust 工作区 vendoring 到 `third_party/codex-rs/`
- 将 macOS 终端崩溃修复依赖 vendoring 到 `third_party/crossterm/`
- `desktop-server` 启动 AI Terminal 时改为优先启动 `sirix-runtime`
- 为 OpenAI-compatible Provider 补齐原生兼容链路，避免错误固定走 Responses API
- 为终端中断场景补齐控制字符即时发送与 TUI 侧主动回查 active turn 的兜底逻辑
- 增加统一构建脚本，编译 `sirix-runtime`、`desktop-server`、`sirix`

## 代码位置

### 1. Sirix CLI / Runtime 启动链路

- `third_party/codex-rs/`
  - vendored 的 Sirix runtime Rust workspace
- `desktop-server/src/app/terminal/manager.rs`
  - 创建 AI Terminal 时直接解析并启动 `sirix-runtime`
  - 补充 Sirix 运行时环境注入与可执行文件定位
- `desktop-server/src/bin/sirix.rs`
  - Sirix CLI 启动入口
- `scripts/build-sirix-cli.sh`
  - 统一编译并安装 `sirix`、`desktop-server`、`sirix-runtime`

### 2. Provider / Model 兼容层

- `desktop-server/src/app/ai/config.rs`
  - 生成 runtime bridge 配置
  - OpenAI-compatible Provider 改为保留真实 `base_url`
  - 根据 Provider 能力写入 `wire_api`
- `desktop-server/src/app/ai/session.rs`
  - AI session 注册表额外记录 provider 信息
  - 方便后续 provider 代理与 runtime 启动时按 session 解析配置
- `desktop-server/src/api/ai.rs`
  - 增加 OpenAI-compatible `/models` 与 `/responses` 兼容代理接口
  - 将兼容请求转换为 provider 可接受的 chat-completions 流式协议
- `desktop-server/src/api/mod.rs`
  - 注册上述 AI 兼容代理路由

### 3. Runtime Core / TUI 能力迁移

- `third_party/codex-rs/model-provider-info/src/lib.rs`
  - 扩展 provider wire api 抽象，增加 `chat`
- `third_party/codex-rs/tools/src/tool_spec.rs`
  - 将 Sirix/Codex 内部工具定义映射为 chat-completions 可用的 function tools
- `third_party/codex-rs/core/src/client.rs`
  - 为 runtime 增加原生 `chat/completions` 流式调用链路
  - 将上游 chunk 归一化为内部 response event
- `third_party/codex-rs/tui/src/app.rs`
  - 处理中断时 active turn 丢失的问题
  - 当本地缓存缺失时主动回查 thread 最新 in-progress turn，再发送 interrupt

### 4. Terminal 输入即时控制

- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
  - 控制字符、`Esc`、`Ctrl+C`、方向键逃逸序列不再走短暂聚合延迟
  - 目的是让 Sirix TUI 类交互在桌面端更接近系统终端的即时反馈

## 实现方法

### 1. 运行时迁移方法

采用 vendoring 方式把 Sirix 当前真正依赖的 Codex Rust runtime 工作区收敛到仓库内，再由 Sirix 自己的构建脚本统一编译。这样做的目的不是长期保留“原样 Codex CLI”，而是先把可运行、可修改、可审查的 runtime 基座纳入 Sirix 仓库，后续继续按 Sirix 设计演进。

### 2. Provider 抽象方法

对 provider 增加 `wire_api` 抽象，让 runtime 调模型时先按抽象层选择协议，再由具体 provider 实现。当前已覆盖：

- `responses`
- `chat`

这样 Sirix 不必把所有 provider 都强行塞进单一 Responses API 语义，也更利于后续支持多 Provider、多模型能力差异。

### 3. 中断兜底方法

中断链路采用“两层兜底”：

- Flutter 侧对控制字符立即 flush，减少前端输入抖动
- TUI/runtime 侧在发送 interrupt 前主动校验 active turn；若缓存缺失，则回查 thread 状态后再中断

这样可以覆盖“前端发出中断但 runtime 本地状态丢失”的场景。

## 当前结论

本次变更后，Sirix CLI 的关键方向已经从“借用 Codex CLI”转为“Sirix 自己编译和控制 runtime，并逐步替换底层实现细节”。`third_party` 当前属于构建期源码依赖，而不是临时参考目录，因此需要进入 Git 管理，后续再按 Sirix 设计持续裁剪和内聚。
