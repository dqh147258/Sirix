# Sirix Native Runtime / Provider Compatibility

## 本次功能

本次提交将 Sirix CLI 从“启动外部 Codex CLI”推进为“由 Sirix 自己管理并编译的本地 runtime 链路”。

当前实现重点包括：

- 将 Sirix CLI 运行时依赖的 Rust 工作区 vendoring 到 `third_party/codex-rs/`
- 将 macOS 终端崩溃修复依赖 vendoring 到 `third_party/crossterm/`
- `desktop-server` 启动 AI Terminal 时改为优先启动 `sirix-runtime`
- 为 Sirix 内嵌 CLI 增加 session 级 provider 代理，统一暴露本地 `/responses` 入口，再按模型路由到真实 Provider
- 为 OpenAI-compatible Provider 补齐 Responses 到 chat-completions 的兼容翻译，并修复 `developer` 角色映射问题
- 为终端中断场景补齐控制字符即时发送与 TUI 侧主动回查 active turn 的兜底逻辑
- 为设置页补齐“关闭模型无需确认”开关，并让工作区配置可以显式覆盖全局配置
- 修复 `/model` 选择器只显示当前 Provider 模型、以及选中后弹层不消失的问题
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

- `client/packages/feature_settings_ai/lib/src/ai_settings_view_model.dart`
  - AI 设置页 ViewModel，增加 `closeModelWithoutConfirmation` 的状态更新入口
- `client/packages/feature_settings_ai/lib/src/sections/cli_settings_section.dart`
  - 在设置页展示 “Close Model Without Confirmation” 开关
- `client/packages/infra_api/lib/src/ai_models.dart`
  - 为 `CliSettingsConfig` 增加 `close_model_without_confirmation` 字段的序列化与反序列化
- `desktop-server/src/app/ai/config.rs`
  - 生成 runtime bridge 配置
  - 为每个 session 注入本地 `sirix-session-proxy` provider
  - 将当前工作区可用的文本模型以内联 `models` 列表注入到 runtime model picker
  - 合并全局/工作区配置时，支持工作区显式关闭 `close_model_without_confirmation`
- `desktop-server/src/app/ai/session.rs`
  - AI session 注册表额外记录当前 session 的全部 provider 路由信息
  - 允许按 `model_id` 解析真实 provider，并在重复模型 id 时优先当前激活 provider
- `desktop-server/src/api/ai.rs`
  - 本地 `/provider/v1/models` 直接返回 session 聚合后的模型列表，而不是只查询当前 provider
  - 本地 `/provider/v1/responses` 按请求中的 `model` 路由到真实 provider
  - OpenAI-compatible provider 走 chat-completions 兼容翻译
  - 原生 Responses provider 继续直通 `/responses`
  - 兼容翻译时把 `developer` role 降级为 `system`，兼容只接受旧角色集合的 provider
- `desktop-server/src/api/mod.rs`
  - 注册上述 AI 兼容代理路由

### 3. Runtime Core / TUI 能力迁移

- `third_party/codex-rs/config/src/config_toml.rs`
  - 为内嵌 runtime 配置增加 `close_model_without_confirmation` 与内联 `models`
- `third_party/codex-rs/core/src/config/mod.rs`
  - 支持从桥接 TOML 中直接构建 model catalog
  - 将退出确认开关接入 runtime 生效配置
- `third_party/codex-rs/core/src/config/config_tests.rs`
  - 增加内联 model catalog 与退出确认开关的配置测试
- `third_party/codex-rs/tui/src/app.rs`
  - 处理中断时 active turn 丢失的问题
  - 当本地缓存缺失时主动回查 thread 最新 in-progress turn，再发送 interrupt
- `third_party/codex-rs/tui/src/bottom_pane/mod.rs`
  - 将 Ctrl+C 弹层处理改为由运行时配置决定是否展示退出确认提示
- `third_party/codex-rs/tui/src/chatwidget.rs`
  - 基于配置决定 Ctrl+C / Ctrl+D 是否需要二次确认退出
  - 修复内联模型列表场景下 `/model` 选中后弹层残留问题
- `third_party/codex-rs/tui/src/chatwidget/tests/*.rs`
  - 增加内联模型列表、退出确认、模型弹层关闭等测试

### 4. Terminal 输入即时控制

- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
  - 控制字符、`Esc`、`Ctrl+C`、方向键逃逸序列不再走短暂聚合延迟
  - 目的是让 Sirix TUI 类交互在桌面端更接近系统终端的即时反馈

## 实现方法

### 1. 运行时迁移方法

采用 vendoring 方式把 Sirix 当前真正依赖的 Codex Rust runtime 工作区收敛到仓库内，再由 Sirix 自己的构建脚本统一编译。这样做的目的不是长期保留“原样 Codex CLI”，而是先把可运行、可修改、可审查的 runtime 基座纳入 Sirix 仓库，后续继续按 Sirix 设计演进。

### 2. Provider 抽象方法

当前 Sirix 内嵌 CLI 采用“本地统一入口 + session 路由”的方式：

- runtime 永远连到本地 `sirix-session-proxy` provider，并使用本地 `/provider/v1/responses`
- 本地代理根据请求里的 `model` 从当前 session 已启用 provider 列表里选择真实 provider
- 对 OpenAI-compatible provider，把 Responses 风格请求翻译成 `chat/completions`
- 对原生支持 Responses 的 provider，直接透传到真实 `/responses`
- `/provider/v1/models` 则返回 session 级聚合模型列表，保证 `/model` 看到的是当前工作区全部可选模型

这样做的目的，是在不大改上游 Codex provider 切换机制的前提下，让 Sirix 先具备“一个 session 内切换不同 provider / model”的能力。它本质上是 Sirix 本地的协议归一化层，而不是要求所有真实上游都支持 Responses API。

### 3. 设置与退出确认方法

`close_model_without_confirmation` 现在从设置页一路打通到运行时：

- Flutter 设置页可直接编辑该开关
- `desktop-server` 生成 bridge 配置时写入 TOML
- 工作区 `.sirix/config.toml` 若显式写了 `false`，可以覆盖全局 `true`
- runtime / TUI 的 Ctrl+C / Ctrl+D 退出行为按该配置决定是否需要二次确认

### 4. 中断兜底方法

中断链路采用“两层兜底”：

- Flutter 侧对控制字符立即 flush，减少前端输入抖动
- TUI/runtime 侧在发送 interrupt 前主动校验 active turn；若缓存缺失，则回查 thread 状态后再中断

这样可以覆盖“前端发出中断但 runtime 本地状态丢失”的场景。

### 5. 模型选择器修复方法

`/model` 相关问题本次通过两部分修复：

- 模型来源改为 session 聚合模型列表，不再只显示当前 provider 的模型
- 当 Sirix 注入的模型预设没有显式 reasoning effort 列表时，选中模型后立即应用，并同步关闭第一层选择弹窗，避免界面残留

## 当前结论

本次变更后，Sirix CLI 的关键方向已经从“借用 Codex CLI”转为“Sirix 自己编译和控制 runtime，并逐步替换底层实现细节”。当前 provider 兼容方案已经演进为“Sirix 本地 session 代理 + 按模型路由真实 provider”，先保证内嵌 CLI 的模型选择与多 provider 配置可用；后续若继续深挖，可以再把 provider 切换下沉到 runtime 原生能力，减少协议适配层的长期复杂度。`third_party` 当前属于构建期源码依赖，而不是临时参考目录，因此需要进入 Git 管理，后续再按 Sirix 设计持续裁剪和内聚。
