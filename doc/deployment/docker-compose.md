# Docker Compose 部署与本地调试

本文档提供 Freeloom 第一阶段的自托管部署建议。

## 1. 部署目标

- 使用单一 `docker compose` 拉起：`postgres`、`redis`、`coturn`、`backend-server`。
- `desktop-server` 运行在桌面机器（不放入 compose，便于本地屏幕采集与本地 WS）。
- 提供一键启动、日志查看、重置脚本。

## 2. 实际文件与脚本

- Compose：`backend-server/deploy/docker-compose.yml`
- Compose 脚本：
  - `backend-server/deploy/scripts/dev-up.sh`
  - `backend-server/deploy/scripts/dev-down.sh`
  - `backend-server/deploy/scripts/dev-logs.sh`
  - `backend-server/deploy/scripts/dev-reset.sh`
- 仓库根目录快捷封装：
  - `scripts/dev-up.sh`
  - `scripts/dev-down.sh`
  - `scripts/dev-logs.sh`
  - `scripts/dev-reset.sh`

## 3. 一键启动

```bash
./scripts/dev-up.sh
./scripts/dev-logs.sh backend-server
```

停止与重置：

```bash
./scripts/dev-down.sh
./scripts/dev-reset.sh
```

## 4. 服务说明

- `postgres`：用户、设备、连接请求、会话、事件流水。
- `redis`：token、在线状态、快照/屏幕缓存。
- `coturn`：WebRTC 媒体中继（自托管）。
- `backend-server`：账号、设备、会话、信令控制平面。

## 5. 配置修改入口

## 5.1 backend-server 配置

文件：`backend-server/config/default.toml`

- 服务监听：`[server].host` / `[server].port`
- 日志：`[logging].level` / `[logging].json`
- PostgreSQL：`[postgres].url`
- Redis：`[redis].url`
- Token TTL：`[auth].access_token_ttl_minutes` / `[auth].refresh_token_ttl_days`
- ICE/TURN：`[webrtc].ice_servers`

环境变量覆盖前缀：`APP__`（双下划线分段）。例如：

- `APP__SERVER__PORT=8080`
- `APP__POSTGRES__URL=postgres://...`
- `APP__WEBRTC__ICE_SERVERS='["stun:...","turn:..."]'`

## 5.2 desktop-server 配置

文件：`desktop-server/config.toml`

- 本地 WS 端口范围：
  - `[local_ws].port_range_start`
  - `[local_ws].port_range_end`
- 快照：`[capture].snapshot_interval_seconds`（默认 5 秒）
- 默认推流：`[stream].default_profile`（默认 `p720`）、`[stream].default_fps`（默认 15）
- backend 接口路径（可按网关前缀改写）：
  - `[backend].health_path`
  - `[backend].heartbeat_path`
  - `[backend].event_ws_path`
  - `[backend].session_decision_path`
  - `[backend].webrtc_signal_path`

环境变量覆盖前缀：`DESKTOP__`。

## 6. TURN 说明

- 当前 compose 启用 UDP/TCP TURN（3478 + relay 端口段）。
- TURN TLS(443) 暂未默认启用，见 `doc/TODO.md` 的网络增强项。

## 7. 生产建议

- backend 前置 HTTPS 反向代理（Nginx/Caddy）。
- Postgres/Redis 使用高可用或托管方案。
- TURN 准备公网域名与证书（进入 TLS 阶段时）。
- 至少保留：应用日志 + 会话事件流水 + 连接质量指标。
