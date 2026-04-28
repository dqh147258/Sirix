# backend-server

Rust 控制平面服务，负责账号、设备、连接请求、会话状态与 WebRTC 信令管理。

- 持久化：PostgreSQL
- 缓存与 token：Redis
- 事件下行：WebSocket（设备流 + 用户流）

## 本地运行

```bash
cd backend-server
CARGO_HOME=/tmp/cargo-home cargo run
```

默认配置读取：

- `config/default.toml`
- `config/${APP_ENV}.toml`（如 `APP_ENV=dev`）

环境变量覆盖前缀：`APP__`（双下划线分段）。

## Docker Compose（推荐）

```bash
./scripts/dev-up.sh
./scripts/dev-up.sh --release
./scripts/dev-up.sh --expose-deps
./scripts/dev-restart.sh --clear-logs
./scripts/dev-logs.sh backend-server
./scripts/dev-down.sh
```

说明：

- 根目录脚本会转发到 `backend-server/deploy/scripts/*`，默认使用 Debug scene。
- `--release` 切到 Release scene；Debug backend 端口是 `46110`，Release backend 端口是 `46120`。
- `--expose-deps` 会额外发布 Postgres / Redis / Coturn 宿主机端口，方便本机工具直连。
- `--build` / `--pull` 需要显式传入；普通 `dev-up.sh` / `dev-restart.sh` 不再默认 rebuild / pull。
- `dev-reset.sh` 等价于 `dev-restart.sh --reset-data`，会删除当前 scene 的 Compose volumes。

## 已落地接口（MVP）

- 认证：
  - `POST /api/v1/auth/register`
  - `POST /api/v1/auth/login`
  - `POST /api/v1/auth/refresh`
- 设备：
  - `POST /api/v1/devices/register`
  - `GET /api/v1/devices/my`
  - `PATCH /api/v1/devices/{device_id}/settings`
  - `GET /api/v1/devices/{device_id}/screens`
  - `GET /api/v1/devices/{device_id}/snapshots`
- 连接/会话：
  - `POST /api/v1/connections/requests`
  - `GET /api/v1/sessions/{session_id}/events`
  - `POST /api/v1/sessions/{session_id}/pause|resume|terminate`
  - `POST /api/v1/sessions/{session_id}/switch-screen`
  - `POST /api/v1/sessions/{session_id}/quality`
- 事件流：
  - `GET /api/v1/desktop/events/{device_id}/ws`
  - `GET /api/v1/mobile/events/ws`
- 桌面控制：
  - `POST /api/v1/desktop/sessions/{session_id}/decision`
  - `POST /api/v1/desktop/devices/{device_id}/heartbeat`
- WebRTC 信令：
  - `POST /api/v1/webrtc/signal`

## 关键行为说明

- 设备注册支持 `preferred_device_id`：
  - 同用户同 `device_id` 会执行幂等更新（更新设备元数据并续活）。
  - 若该 `device_id` 属于其他用户，返回冲突 `DEVICE_ID_CONFLICT`。
- 桌面决策接口幂等：重复提交同一结果会返回 `applied=false`。
- 连接请求会同步维护 `connection_requests.status` 与 `share_sessions.state`。
- 所有会话控制、决策、信令会写入 `session_events` 供排障追溯。
- 后台暂停超时由服务端强制终止：
  - `pause` 后 3 分钟超时（由 `pause_deadline_at` 决定）
  - 后端后台任务每 10 秒扫描并终止过期会话
  - 事件下发：
    - 移动端：`session.auto_terminated`
    - 桌面端：`session.control.terminate`（`reason=pause_timeout`）
