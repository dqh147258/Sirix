# desktop-server

Rust 桌面代理服务，负责：

- 订阅 backend 桌面事件流。
- 执行授权决策（自动授权 / 手动授权 / 超时拒绝）。
- 与桌面 Flutter 客户端通过本地 WebSocket 协作。
- 心跳上报、信令上行、会话控制事件转发。

## 本地运行

```bash
cd desktop-server
CARGO_HOME=/tmp/cargo-home cargo run
```

## 配置文件

- `desktop-server/config.toml`

关键字段：

- 本地端口范围：`[local_ws].port_range_start` / `port_range_end`（默认 `9700-9710`）
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
- `authorize.request`
- `authorize.ack`
- `webrtc.signal.ack`
- 透传 `session.control.*` 与 `webrtc.*`

## 后台任务

- 心跳探活：请求 backend `/health` 与 heartbeat 接口。
- 事件订阅：连接 backend 桌面事件 WS，断线自动重连。
- 快照调度：按配置周期输出采样 tick（当前为骨架日志）。
