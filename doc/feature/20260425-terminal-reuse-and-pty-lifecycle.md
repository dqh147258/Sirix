# Terminal Reuse and PTY Lifecycle Hardening

## 功能说明

本次收口 `sirix` / `sirix-terminal` / desktop-server terminal runtime 的若干生命周期边界，目标是让 Desktop App terminal 内启动 AI runtime 的 `reuse_current_terminal` 分支继续成立，同时降低嵌套、fallback PTY 不稳定和 tmux 残留风险。

## 代码位置

- `desktop-server/src/bin/sirix.rs`
- `desktop-server/src/app/ai/session.rs`
- `desktop-server/src/app/terminal/manager.rs`
- `desktop-server/src/api/ws.rs`
- `desktop-server/src/main.rs`
- `desktop-server/src/terminal_launch.rs`

## 实现方法

1. **current-terminal reuse 能力边界**：
   - `sirix` 不再只依赖 `SIRIX_TERMINAL_SESSION_ID`，而是同时读取 `SIRIX_TERMINAL_KIND`。
   - 只有普通受管 shell（`local_pty` / `desktop_shell` / 旧环境缺省 kind）会作为 `reuse_terminal_id` 传给 desktop-server。
   - `ai_runtime`、hosted 或未知 kind 不参与 current-terminal reuse，避免特殊生命周期 terminal 内继续套娃启动。

2. **AI runtime 环境一致性**：
   - `CurrentTerminalLaunch` 补充 `terminal_id`、`ai_session_id`、`local_api_base`、`terminal_kind`。
   - `sirix` 在 current-terminal 分支启动 AI runtime 时注入 `SIRIX_TERMINAL_SESSION_ID`、`SIRIX_TERMINAL_KIND`、`SIRIX_AI_SESSION_ID`、`SIRIX_LOCAL_API_BASE`。
   - server-owned `create_codex_terminal()` 也注入 terminal id，并将 kind 覆盖为 `ai_runtime`。

3. **system terminal attach 收敛**：
   - `sirix` 的 raw-v1 attach 路径对齐 `sirix-terminal`：收到 `terminal.ready` 后标记 attach 成功，退出前显式发送 `terminal.detach`。
   - 这样可以缩短 system-terminal viewer 的 geometry authority 回收时间，仍保留 websocket disconnect cleanup 兜底。

4. **fallback/legacy PTY 稳定性**：
   - legacy/fallback PTY 显式设置 `TERM=xterm-256color` 和 `COLORTERM=truecolor`，避免继承 GUI/service 进程的空值或 `dumb`。
   - PTY writer 写入失败时记录 `[TERMINAL_PTY_TRACE]` 并主动关闭 session，避免坏 writer 的 session 长时间悬挂。
   - raw-v1 websocket receiver lagged 后，会尝试向当前 raw terminal socket 补发 output snapshot，降低大输出丢事件后的不可恢复概率。

5. **desktop-server shutdown 清理**：
   - `main.rs` 改为使用 axum graceful shutdown，SIGINT / SIGTERM / serve error / serve loop exit 都会调用 `TerminalManager::shutdown_cleanup()`。
   - shutdown cleanup 会关闭当前内存中的 terminal runtime，并沿现有 close path 清理 tmux session。

6. **tmux 生命周期策略**：
   - 新增 `SIRIX_TMUX_LIFECYCLE` 环境变量。
   - 默认仍保持 takeover 语义：desktop-server 异常退出后保留 tmux session，便于下次启动接管。
   - 设置 `SIRIX_TMUX_LIFECYCLE=server_bound`（也支持 `server-bound` / `serverbound` / `bound`）时，`apply_tmux_session_defaults()` 会为 session 设置 `destroy-unattached on`，尽量让 tmux session 随 desktop-server 持有的 tmux client 断开而销毁。

## 验证

- `cargo fmt --manifest-path desktop-server/Cargo.toml`
- `cargo check --manifest-path desktop-server/Cargo.toml`
- `cargo test --manifest-path desktop-server/Cargo.toml terminal_launch -- --nocapture`
- `cargo test --manifest-path desktop-server/Cargo.toml current_terminal -- --nocapture`

## 注意事项

- `SIRIX_TMUX_LIFECYCLE=server_bound` 是 opt-in，避免默认破坏 tmux takeover 恢复能力。
- Rust graceful shutdown 无法处理 `kill -9`、机器断电等不可恢复场景；这些场景只能依赖 tmux 自身 option 或后续 watchdog/sentinel 机制。
