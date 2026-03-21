# 接口与协议设计（MVP）

本文档定义当前代码已落地的 HTTP / WebSocket / WebRTC 信令契约。

## 1. 通信矩阵

- 移动 Flutter Client ↔ `backend-server`：HTTP + WebSocket（移动事件流）。
- 桌面 Flutter Client ↔ `desktop-server`：本地 WebSocket（`127.0.0.1:9700-9710`）。
- `desktop-server` ↔ `backend-server`：HTTP（心跳/决策/信令上行）+ WebSocket（桌面事件流）。
- 移动 Flutter Client ↔ 桌面端：WebRTC 媒体（当前阶段为信令转发 + TURN，媒体直连/中继按网络自动选择）。

## 2. 鉴权约定

- Access Token：默认 15 分钟（Redis TTL）。
- Refresh Token：默认 30 天（Redis TTL）。
- 移动端/桌面 Flutter 对 backend 的用户态接口使用：`Authorization: Bearer <access_token>`。
- `desktop-server` 到 backend 的桌面控制接口当前通过 `device_id` 做设备维度校验（后续可增强为服务间签名鉴权）。

## 3. backend-server HTTP API

## 3.1 认证

- `POST /api/v1/auth/register`
  - 入参：`username`, `password`
  - 返回：`user_id`, `username`, `access_token`, `refresh_token`

- `POST /api/v1/auth/login`
  - 入参：`username`, `password`, `client_type`
  - 返回：同上

- `POST /api/v1/auth/refresh`
  - 入参：`refresh_token`
  - 返回：新 token 对

## 3.2 设备管理

- `POST /api/v1/devices/register`
  - 入参：
    - `device_name`
    - `platform`
    - `client_version`
    - `preferred_device_id`（可选）
  - 返回设备信息（含 `online`）
  - 语义：
    - 若 `preferred_device_id` 不存在：创建新设备。
    - 若存在且归属当前用户：执行幂等更新（设备信息 + `last_seen_at`）。
    - 若存在但归属其他用户：返回 `DEVICE_ID_CONFLICT`。

- `GET /api/v1/devices/my`
  - 返回当前账号下设备列表（含 `online`）

- `PATCH /api/v1/devices/{device_id}/settings`
  - 入参：`auto_approve_screen_share: bool`

- `GET /api/v1/devices/{device_id}/screens`
  - 返回屏幕元数据列表

- `GET /api/v1/devices/{device_id}/snapshots`
  - 返回屏幕缩略图列表（低分辨率，默认 5 秒刷新）

## 3.3 连接请求与会话

- `POST /api/v1/connections/requests`
  - 入参：`target_device_id`, `initial_quality_profile`
  - 返回：`request_id`, `session_id`, `status`, `state`
  - 说明：
    - 若设备开启自动授权，`status=accepted`，`state=connecting`
    - 否则 `status=requested`，`state=pending_approval`

- `GET /api/v1/sessions/{session_id}/events?limit=50`
  - 返回会话事件流水（按时间升序）

- `POST /api/v1/sessions/{session_id}/pause`
- `POST /api/v1/sessions/{session_id}/resume`
- `POST /api/v1/sessions/{session_id}/terminate`
- `POST /api/v1/sessions/{session_id}/switch-screen`
  - 入参：`screen_id`
- `POST /api/v1/sessions/{session_id}/quality`
  - 入参：`mode(manual|auto)`, `profile(p480|p720|p1080)`

## 3.4 桌面控制（desktop-server 调用）

- `POST /api/v1/desktop/devices/{device_id}/heartbeat`
  - 入参：`source`（可选）

- `POST /api/v1/desktop/sessions/{session_id}/decision`
  - 入参：`device_id`, `decision(approve|reject)`, `reason`
  - 返回：`applied`（幂等结果）、`request_status`、`state`

## 3.5 WebRTC 信令转发

- `POST /api/v1/webrtc/signal`
  - 入参：
    - `session_id`
    - `role`：`mobile | desktop`
    - `signal_type`：`offer | answer | ice_candidate`
    - `sdp`（offer/answer）
    - `candidate`（ice）
    - `device_id`（desktop 角色必填）

## 4. 事件通道（WebSocket）

## 4.1 backend 事件 Envelope

```json
{
  "type": "session.requested",
  "event_id": "evt_123",
  "timestamp": "2026-02-15T10:00:00Z",
  "payload": {}
}
```

## 4.2 desktop-server 订阅（来自 backend）

- `GET /api/v1/desktop/events/{device_id}/ws`
- 常见事件：
  - `session.requested`
  - `session.control.pause`
  - `session.control.resume`
  - `session.control.terminate`
  - `session.control.switch_screen`
  - `session.control.quality_changed`
  - `webrtc.offer`
  - `webrtc.answer`
  - `webrtc.ice_candidate`

## 4.3 mobile-client 订阅（来自 backend）

- `GET /api/v1/mobile/events/ws`（Bearer Token）
- 常见事件：
  - `connection.request.created`
  - `connection.request.accepted`
  - `connection.request.rejected`
  - `session.state.changed`
  - `session.auto_terminated`
  - `webrtc.offer`
  - `webrtc.answer`
  - `webrtc.ice_candidate`

## 5. desktop-server 与桌面 Flutter 的本地 WS 协议

默认监听：`127.0.0.1:9700-9710`。

- desktop-server -> Flutter Desktop
  - `settings.sync`
    - `{ "auto_approve_screen_share": bool, "device_id": "uuid", "local_ws_port": 9700 }`
  - `authorize.request`
  - 透传控制/信令事件：`session.control.*`、`webrtc.*`

- Flutter Desktop -> desktop-server
  - `settings.set_auto_approve`
    - `{ "auto_approve_screen_share": true|false }`
  - `authorize.response`
    - `{ "session_id": "...", "decision": "approve|reject" }`
  - `webrtc.signal`
    - `{ "session_id": "...", "signal_type": "offer|answer|ice_candidate", "sdp": "...", "candidate": {...} }`

> 兼容性：桌面本地 WS 也接受历史 snake_case 类型名（如 `authorize_response`）。

## 6. 会话状态机（当前实现）

- `requested | pending_approval -> connecting -> streaming`
- `streaming -> paused -> streaming`
- 任意状态 -> `terminated`

规则：

- 桌面决策接口为幂等：重复提交相同决策返回 `applied=false`。
- 移动端进入后台后保持会话 3 分钟；超时会触发终止。
- 服务端有超时兜底任务：扫描 `pause_deadline_at` 过期会话并强制终止。

## 7. 错误码（当前实现）

- `AUTH_INVALID_CREDENTIALS`
- `AUTH_TOKEN_EXPIRED`
- `DEVICE_NOT_FOUND`
- `DEVICE_NOT_OWNED`
- `DEVICE_ID_CONFLICT`
- `SESSION_NOT_FOUND`
- `SESSION_NOT_ACTIVE`
- `SESSION_DECISION_CONFLICT`
- `CONNECTION_INTERNAL`
- `WEBRTC_INTERNAL`
