# 系统架构设计（MVP）

## 1. 目标与设计原则

## 1.1 目标

- 支持移动端（Android/iOS）远程查看桌面端屏幕共享。
- 支持桌面端（macOS Intel/M1、Windows）登录与授权控制。
- 支持账号体系统一管理、设备在线管理、会话编排与审计。
- 保持高扩展性，为后续跨账号协助、语音通道、命令行通道预留。

## 1.2 关键设计原则

- 控制平面与媒体平面分离：`backend-server` 管理控制，媒体由 WebRTC 承载。
- 先信令后增强：MVP 先完成信令 + TURN 中继；SFU/媒体服务后续演进。
- 统一鉴权：所有端都通过 `backend-server` 进行身份校验与短期令牌交换。
- 模块化可替换：Flutter 使用 `melos` 管理多模块；Rust 使用分层架构。
- 观测优先：Rust 服务全量结构化日志，日志级别可配置，默认 `trace`。

## 2. 组件职责

## 2.1 backend-server（Rust）

职责：

- 账号与会话管理：注册、登录、刷新 token、登出。
- 设备管理：设备注册、在线状态、设备策略（自动授权等）。
- 连接管理：移动端发起请求、路由到目标 desktop-server、结果回传。
- WebRTC 信令：offer/answer/ICE candidate 转发。
- 可观测性：审计日志、错误追踪、会话事件流水。

外部依赖：

- PostgreSQL：持久化用户、设备、会话、策略、审计元数据。
- Redis：在线状态、短时会话态、限流与幂等键。
- Coturn（自托管）：NAT 穿透失败时走 TURN 中继。

## 2.2 desktop-server（Rust）

职责：

- 维护与 backend 的连接（鉴权、心跳、会话指令收发）。
- 屏幕采集与编码，作为 WebRTC 发布端（Publisher）。
- 将授权请求转发给本机桌面 Flutter 客户端；执行授权策略。
- 多屏管理：可枚举屏幕、生成缩略图（低分辨率 JPEG/WebP）。

本机对接：

- 与 Flutter Desktop Client 使用 WebSocket（本地环回地址）通信。

## 2.3 client（Flutter）

移动端职责：

- 账号登录。
- 列出同账号下桌面设备与在线状态。
- 发起连接、接收视频流、切换屏幕与分辨率。
- 手动横竖屏切换；退后台触发 3 分钟保活策略。

桌面端职责：

- 账号登录。
- 设置设备级自动授权（默认关闭）。
- 接收授权弹窗并允许/拒绝。

## 3. 技术架构与目录建议

## 3.1 client（Flutter + Melos）

建议目录：

```text
client/
  melos.yaml
  apps/
    mobile_app/
    desktop_app/
  packages/
    app_core/                # 路由、主题、基础错误处理、日志封装
    feature_auth/            # 登录注册
    feature_device_list/     # 设备列表
    feature_remote_view/     # 屏幕查看、分辨率、横竖屏
    feature_desktop_authorize/# 桌面授权开关与授权请求处理
    infra_api/               # REST/WS API
    infra_webrtc/            # WebRTC 封装（PeerConnection、stats）
```

架构模式：

- 状态管理：Riverpod。
- 视图组织：MVVM（`View` / `ViewModel` / `State` / `Repository`）。
- 跨平台差异通过包依赖组合控制，不在共享层硬编码平台分支。

## 3.2 backend-server（Rust）

建议分层：

```text
backend-server/
  src/
    api/          # axum handlers + DTO
    application/  # 用例编排（service）
    domain/       # 领域实体、规则、策略
    infrastructure/
      db/         # sqlx repos
      cache/      # redis repos
      rtc/        # signaling + turn config
      auth/       # jwt/refresh token
    bootstrap/    # config/logging/http server init
  migrations/
  config/
    default.toml
    dev.toml
```

建议栈：`axum + tokio + sqlx + redis + tracing + anyhow/thiserror + serde`。

## 3.3 desktop-server（Rust）

建议分层：

```text
desktop-server/
  src/
    api_local/    # 与桌面 Flutter 本地 websocket 协议
    app/          # 会话编排（授权、推流、暂停、切屏）
    capture/      # 多屏捕获与缩略图
    rtc/          # WebRTC peer 发布端
    backend/      # backend HTTP/WS 客户端
    config/
```

## 4. 数据模型（可扩展）

## 4.1 核心表

- `users`
  - `id`, `username`, `password_hash`, `status`, `created_at`。
- `auth_identities`（预留邮件/OAuth）
  - `user_id`, `identity_type`, `identity_value`, `verified_at`。
- `devices`
  - `id`, `user_id`, `device_name`, `platform`, `client_version`, `last_seen_at`。
- `device_settings`
  - `device_id`, `auto_approve_screen_share`（设备维度）。
- `connection_requests`
  - `id`, `requester_user_id`, `target_device_id`, `status`, `created_at`。
- `share_sessions`
  - `id`, `request_id`, `state`, `selected_screen_id`, `quality_profile`, `started_at`, `ended_at`。
- `session_events`
  - 会话事件流水（创建、授权、拒绝、暂停、恢复、断开、错误）。

## 4.2 Redis 键建议

- `presence:device:{device_id}` -> 在线心跳与连接元信息。
- `ws-route:desktop:{device_id}` -> backend 到 desktop-server 路由映射。
- `session:ephemeral:{session_id}` -> 会话短期状态（暂停倒计时等）。
- `rate-limit:*` -> 登录与关键接口限流。

## 5. 关键流程（时序）

## 5.1 登录与设备在线

1. 桌面端 Flutter 登录 -> backend 签发 token。
2. desktop-server 使用 token 绑定设备并建立长连接心跳。
3. 移动端登录后拉取“同账号设备列表 + 在线状态”。

## 5.2 发起屏幕共享

1. 移动端选择设备，调用 backend 创建 `connection_request`。
2. backend 路由请求到目标 desktop-server。
3. desktop-server 判断设备策略：
   - 自动授权开启：直接进入会话。
   - 自动授权关闭：询问桌面 Flutter 客户端。
   - 若需手动授权但桌面 Flutter 未连接：自动拒绝。
4. 授权通过后，进行 WebRTC 协商并开始推流。

## 5.3 退后台与暂停策略

1. 移动端进入后台/退出观看页，发送 `pause`。
2. desktop-server 降低资源占用并保持会话保活计时。
3. 3 分钟内恢复则 `resume`；超时自动 `terminate`。

## 5.4 多屏与快照

1. desktop-server 周期性生成屏幕缩略图（默认 5 秒，可配置）。
2. 移动端打开屏幕选择页时读取最近一批快照。
3. 用户切换目标屏幕后，desktop-server 切换采集源。

## 6. 分辨率与自适应策略

## 6.1 手动档位

- `流畅(480P)`、`标清(720P)`、`高清(1080P)`。
- 实际输出按原始宽高比计算，避免强制拉伸：
  - 21:9、4:3 等均按“目标像素等级 + 原始比例”推导目标宽高。

示例：

- 21:9 屏幕 720 档位可输出约 `1680x720` 或等效像素预算。
- 4:3 屏幕 720 档位可输出约 `960x720`。

## 6.2 动态自适应（Auto）

根据 WebRTC 统计自动降/升档，核心信号：

- 可用带宽估计（send/recv bitrate）。
- 丢包率（packet loss）。
- RTT 抖动与帧渲染延迟。

建议策略：

- 连续 5 秒高丢包或高 RTT：降一级。
- 连续 15 秒稳定且有带宽余量：升一级。
- 任意级别切换均设置最短冷却时间，避免抖动。

默认参数：

- 默认档位：`720P`。
- 默认帧率：`15fps`。

## 7. 安全与可靠性

## 7.1 安全

- 密码：`argon2id` 哈希 + 随机盐。
- 令牌：短期 Access Token + 长期 Refresh Token。
- 会话授权：一次性 `share_grant_token`，仅在单会话内有效。
- 接口防护：登录/注册限流；关键动作审计。

## 7.2 可靠性

- desktop-server 与 backend 断连自动重连（指数退避）。
- 会话状态机幂等处理，重复消息不重复生效。
- 关键事件写入 `session_events` 便于故障回放。

## 7.3 可观测性

- 全链路结构化日志（JSON 可选）。
- 日志级别可配置：`trace/debug/info/warn/error`，默认 `trace`。
- 建议引入 metrics：请求耗时、会话时长、授权成功率、ICE 失败率。

## 8. 配置设计

## 8.1 backend-server 配置文件

- 默认路径：`backend-server/config/default.toml`
- 环境覆盖：`backend-server/config/dev.toml`、`prod.toml`

示例字段：

```toml
[server]
host = "0.0.0.0"
port = 8080

[logging]
level = "trace"
json = false

[postgres]
url = "postgres://freeloom:freeloom@postgres:5432/freeloom"

[redis]
url = "redis://redis:6379"

[webrtc]
ice_servers = [
  "stun:stun.l.google.com:19302",
  "turn:coturn:3478?transport=udp"
]
```

## 8.2 desktop-server 配置文件

- 默认路径：`desktop-server/config.toml`

示例字段：

```toml
[backend]
base_url = "http://127.0.0.1:8080"

[local_ws]
host = "127.0.0.1"
port_range_start = 9700
port_range_end = 9710

[capture]
snapshot_interval_seconds = 5
snapshot_width = 480

[stream]
default_profile = "p720"
default_fps = 15
auto_adapt = true

[logging]
level = "trace"
```

说明：本地 WebSocket 默认端口范围 `9700-9710`，可在该配置文件中修改。


## 8.3 接口路径可配置（网关友好）

`desktop-server` 对 backend 的路径均可在 `desktop-server/config.toml` 中改写：

- `[backend].health_path`
- `[backend].heartbeat_path`
- `[backend].event_ws_path`
- `[backend].session_decision_path`
- `[backend].webrtc_signal_path`

这使得在网关/反向代理增加前缀（如 `/freeloom/api/...`）时，无需重新编译 `desktop-server`。
