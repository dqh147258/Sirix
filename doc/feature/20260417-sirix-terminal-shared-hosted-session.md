# Sirix Terminal Shared Hosted Session

## 功能说明

本次新增 `sirix-terminal` 命令，用于在系统 Terminal 中发起一个可被 Sirix Desktop / Mobile 同步观察和交互的共享终端会话。

和 `sirix` AI 会话不同，`sirix-terminal` 不接管当前父 shell，而是启动一个新的子 shell PTY 并把它作为 hosted terminal 挂到 desktop-server。这样可以保持系统 Terminal 的行为稳定，同时复用 Sirix 现有 terminal session、backend 同步和多端展示链路。

同时本次对 sirix 相关链路做了公共层抽象，避免 `sirix` 与 `sirix-terminal` 在 desktop-server 探测、登录检查、raw mode、stdin 读取等基础能力上重复实现。

## 代码位置

- `desktop-server/src/cli_support.rs`
- `desktop-server/src/bin/sirix.rs`
- `desktop-server/src/bin/sirix-terminal.rs`
- `desktop-server/src/api/terminals.rs`
- `desktop-server/src/api/ws.rs`
- `desktop-server/src/api/mod.rs`
- `desktop-server/src/api/ai.rs`
- `desktop-server/src/app/terminal/manager.rs`
- `desktop-server/src/app/ai/config.rs`
- `scripts/build-sirix-cli.sh`
- `client/packages/infra_api/lib/src/models.dart`
- `client/packages/infra_api/lib/src/desktop_local_client.dart`
- `client/packages/infra_api/lib/src/http_backend_api_client.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
- `client/packages/feature_terminal/lib/src/terminal_page.dart`
- `doc/development/20260417/sirix-terminal-plan.md`
- `doc/development/20260417/sirix-terminal-todo.md`

## 实现方法

1. **CLI 公共能力抽象**：
   - 将 `sirix` 与 `sirix-terminal` 共用的 desktop-server 启动探测、本地登录检查、终端 raw mode、stdin reader 等逻辑下沉到 `cli_support.rs`。
   - 统一使用 `SIRIX_TERMINAL_SESSION_ID` 作为当前受管 terminal 环境变量，避免不同入口各自定义嵌套判定。

2. **Hosted terminal session 抽象**：
   - `TerminalManager` 从原本只管理本地 PTY，扩展为统一管理 `LocalPty` 与 `Hosted` 两类 endpoint。
   - 两类 session 共用 terminal metadata、replay buffer、本地事件广播和 backend terminal output/state 同步能力。
   - hosted session 在 host 连接成功后会把本地 snapshot 状态从 `opening` 切到 `active`，避免 Desktop UI 长时间停留在 opening。

3. **desktop-server 本地 hosted API 与 WS 协议**：
   - 新增 `POST /terminals/hosted/sessions`，由 `sirix-terminal` 先创建 hosted terminal session。
   - 新增 `terminal.host.register / output / resized / closed / error` 协议，供系统 Terminal 宿主向 desktop-server 汇报 PTY 生命周期。
   - 新增 `terminal.host.input / resize / close` 下行命令，让 Desktop App 中的输入和窗口大小变化能回写到系统 Terminal 的 PTY 子 shell。

4. **复用 backend terminal pipeline 以支持 Mobile**：
   - 创建 hosted terminal 时，如果 desktop-server 已登录 backend 且 backend event stream 已连接，则先调用现有 `/api/v1/desktop/terminals/local` 创建 backend terminal session。
   - 这样 hosted session 的输出、状态更新和关闭事件会沿现有 backend terminal 同步链路继续分发，Mobile 无需新增单独协议即可看到 `sirix-terminal` 创建的终端。
   - 若 backend 不可用，则自动降级为 local-only hosted terminal，避免命令执行被远端状态卡死。

5. **系统 Terminal 宿主实现**：
   - `sirix-terminal` 通过本地 WS 注册 host 身份后，在本机创建子 shell PTY。
   - 用户在系统 Terminal 中输入的内容会写入 PTY；PTY 输出会同时回显到当前 stdout，并通过 hosted 协议转发到 desktop-server。
   - Desktop App 对该 terminal 的输入、resize、关闭操作会反向写入 PTY 或结束子进程。
   - 子 shell 环境会补齐 `~/.sirix/bin`、`SIRIX_HOME`，并写入 `SIRIX_TERMINAL_SESSION_ID`，从而阻止在 Sirix 托管终端内部再次执行 `sirix-terminal` 套娃。

6. **Desktop UI 来源标识**：
   - local terminal snapshot 新增 `source` 字段，Desktop 本地 terminal tab 在识别到 hosted session 时显示 `HOST` 标记。
   - Mobile / backend 侧当前仍通过固定标题 `Sirix Terminal` 识别该会话，保证兼容现有远端 terminal summary 结构。

7. **hosted shell 内 `sirix` 防套娃**：
   - `sirix-terminal` 创建的子 shell 现在会额外写入 `SIRIX_TERMINAL_KIND=hosted_shell`，不再只靠 `SIRIX_TERMINAL_SESSION_ID` 模糊判断。
   - `sirix` 在检测到自己运行于 hosted shell 时，不会再把当前 terminal 作为 `reuse_terminal_id` 传给 desktop-server，而是改为创建一个独立的 AI session，并提示用户去 Desktop / Mobile 或系统 Terminal 继续查看。
   - `sirix resume` 在 hosted shell 中会直接拒绝，避免再次在 hosted shell 内 attach 另一个 Sirix terminal。
   - backend / desktop-server 侧也增加了 terminal source 校验，即使外部调用者手动传入 hosted terminal id，也会被拒绝作为 current-terminal reuse 目标。

8. **构建与安装链路补齐**：
   - `scripts/build-sirix-cli.sh` 现在会一并构建安装 `sirix-terminal`。
   - desktop-server 的 bin shim 安装逻辑也会把 `sirix-terminal` 放入 `~/.sirix/bin`，保证受管终端与系统环境都能直接调用。

9. **测试与验证**：
   - 为 `TerminalManager` 新增 hosted terminal 生命周期单测，覆盖注册鉴权、输入转发、resize 转发、close 关闭和断线错误收敛。
   - 另补充了 hosted terminal 不能作为 current-terminal reuse 目标的单测，确保 `sirix-terminal` 内执行 `sirix` 不会再回到复用当前 hosted shell 的旧路径。
   - 已完成 `cargo test --manifest-path desktop-server/Cargo.toml hosted_terminal -- --nocapture` 与 `cargo check --manifest-path desktop-server/Cargo.toml`。
   - 当前环境下 `dart analyze` / `dart format` 触发 Dart VM 崩溃，因此 Flutter 侧仅完成代码接线和 diff/空白检查，Desktop/Mobile 真机联调需在可用 Dart/Flutter 环境中继续执行。
