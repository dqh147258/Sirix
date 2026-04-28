# desktop-server

Rust 桌面代理服务，负责：

- 订阅 backend 桌面事件流。
- 执行授权决策（自动授权 / 手动授权 / 超时拒绝）。
- 与桌面 Flutter 客户端通过本地 WebSocket 协作。
- 心跳上报、信令上行、会话控制事件转发。
- macOS / Linux 本机屏幕枚举与预览快照上报。

## 本地运行

推荐脚本：

```bash
./scripts/run-desktop-server.sh
./scripts/run-desktop-server.sh --clear-logs
./scripts/run-desktop-server.sh --release
./scripts/run-desktop-server.sh --background
```

说明：

- 默认启动 Debug scene；附带 `--release` 时切到 Release scene。
- `--clear-logs` 会清理当前 scene 对应的 backend runtime logs，便于重新观察桌面代理联调日志。
- `--background` 会把 desktop-server 放到后台运行，并把日志写入 `${SIRIX_HOME}/runtime/logs/desktop-server.log`。
- 启动脚本会同时构建 `desktop-server`、`sirix`、`sirix-terminal` 与 `sirix-runtime`，并把 scene-aware shim 安装到 `${SIRIX_HOME}/bin`。

若需要直接在 `desktop-server/` 目录手动运行：

```bash
cd desktop-server
CARGO_HOME=/tmp/cargo-home cargo run
```

Linux 说明：

- `desktop-server` 现已支持 Linux 桌面环境。
- 快照与屏幕枚举依赖当前图形会话；若运行在无图形会话的纯 CLI 环境，屏幕采集会失败并输出告警日志。

## 配置文件

- `desktop-server/config.toml`

关键字段：

- 本地端口范围：`[local_ws].port_range_start` / `port_range_end`（默认 Debug `46111-46119`，Release `46121-46129`）
- 快照刷新：`[capture].snapshot_interval_seconds`（默认 `5`）
- 默认流参数：`[stream].default_profile`（`p720`）、`default_fps`（`15`）
- backend 连接：
  - `base_url`
  - `health_path`
  - `heartbeat_path`
  - `event_ws_path`
  - `session_decision_path`
  - `webrtc_signal_path`
  - `device_id`

环境变量覆盖前缀：`DESKTOP__`（双下划线分段）。

补充：

- `SIRIX_SCENE=debug|release` 会为 `backend.base_url`、默认 `device_id`、本地 WS 端口段注入 scene 默认值。
- `SIRIX_HOME` 默认按 scene 选择：Debug `~/.sirix-debug`，Release `~/.sirix`。

## Sirix CLI

`desktop-server` workspace 产出三个本地二进制：`desktop-server`、`sirix`、`sirix-terminal`。推荐用仓库根目录脚本构建安装：

```bash
./scripts/build-sirix-cli.sh
./scripts/build-sirix-cli.sh --release
```

安装位置：

- Debug：`~/.sirix-debug/bin`
- Release：`~/.sirix/bin`

常用命令：

```bash
sirix
sirix list
sirix resume <ai_session_id|terminal_id>
sirix-terminal
```

说明：

- `sirix` 会探测本地 desktop-server；未运行时会尝试启动同目录下的 `desktop-server`。
- `sirix` 用于创建或恢复 Sirix AI coding session，session 会镜像到 Desktop / Mobile。
- `sirix-terminal` 会在系统 Terminal 中启动一个共享 shell PTY，并通过本地 WS 挂到 desktop-server；Desktop / Mobile 可以同步查看、输入、resize 和关闭。
- `sirix-terminal` 会给子 shell 注入 `SIRIX_TERMINAL_SESSION_ID`、`SIRIX_TERMINAL_KIND=hosted_shell`、`SIRIX_HOME` 和 scene bin `PATH`，因此不要在 hosted shell 内再次启动 `sirix-terminal`。

## 本地接口

- `GET /health`
- `GET /settings`
- `PATCH /settings`
- `GET /ws`（桌面 Flutter 本地 WebSocket）

## 本地 WS 协议

Flutter -> desktop-server：

- `settings.set_auto_approve`
- `authorize.response`
- `webrtc.signal`
- `ping`

desktop-server -> Flutter：

- `settings.sync`
  - `auto_approve_screen_share`
  - `device_id`
  - `local_ws_port`
- `authorize.request`
- `authorize.ack`
- `webrtc.signal.ack`
- 透传 `session.control.*` 与 `webrtc.*`

## 后台任务

- 心跳探活：请求 backend `/health` 与 heartbeat 接口。
- 事件订阅：连接 backend 桌面事件 WS，断线自动重连。
- 快照调度：按配置周期采集本机屏幕列表与缩略图并上报 backend。

## 与 Flutter 桌面端协作说明

- `device_id` 由 `desktop-server/config.toml` 提供，并在 `settings.sync` 中下发。
- Flutter 桌面端登录后，会用该 `device_id` 向 backend 做设备注册/续活（幂等）。
- 自动授权开关会同步到 backend 的设备设置，保证移动端发起连接时策略一致。
- Linux 下 `screen_id` 会附带桌面源提示，供 Flutter 桌面端把 backend 的目标屏幕映射回本地 `desktopCapturer` 源。
