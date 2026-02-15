# 三端调试与部署指南（client / desktop-server / backend-server）

本文档是 Freeloom 三端联调与部署的独立说明，覆盖本地开发、问题排查、预发布与生产部署。

## 1. 目录与职责

- `client/`：Flutter 客户端（移动端 + 桌面端）。
- `desktop-server/`：桌面代理服务（Rust，连接 backend + 本地 Flutter）。
- `backend-server/`：控制平面服务（Rust，账号、设备、会话、信令）。

## 2. 先说清楚：client 的“平台工程在哪里”

当前仓库采用 **单 Flutter 壳工程 + 多入口模块** 模式：

- 平台工程在：`client/android`、`client/ios`、`client/macos`、`client/windows`。
- 业务入口在：
  - 移动端入口 `client/apps/mobile_app/lib/main.dart`
  - 桌面端入口 `client/apps/desktop_app/lib/main.dart`

也就是说，`apps/mobile_app` 与 `apps/desktop_app` 本身是入口模块，不是独立平台壳工程。

## 3. 本地联调（推荐顺序）

## 3.1 启动 backend 及依赖

```bash
./scripts/dev-up.sh
./scripts/dev-logs.sh backend-server
```

这会拉起：`postgres`、`redis`、`coturn`、`backend-server`。

## 3.2 启动 desktop-server

```bash
cd desktop-server
CARGO_HOME=/tmp/cargo-home cargo run
```

关键配置文件：`desktop-server/config.toml`

- `backend.base_url`
- `backend.device_id`
- `backend.event_ws_path`
- `backend.heartbeat_path`
- `backend.session_decision_path`
- `backend.webrtc_signal_path`

## 3.3 启动 Flutter 客户端（从 `client/` 根目录启动）

### 移动端

```bash
./scripts/run-mobile-client.sh
```

或手动：

```bash
cd client
flutter run -t apps/mobile_app/lib/main.dart \
  --dart-define=FREELOOM_USE_MOCK=false \
  --dart-define=FREELOOM_API_BASE_URL=http://127.0.0.1:8080
```

### 桌面端（macOS / Windows）

```bash
./scripts/run-desktop-client.sh -d macos
```

或手动：

```bash
cd client
flutter run -t apps/desktop_app/lib/main.dart -d macos \
  --dart-define=FREELOOM_USE_MOCK=false \
  --dart-define=FREELOOM_API_BASE_URL=http://127.0.0.1:8080 \
  --dart-define=FREELOOM_DESKTOP_SERVER_HOST=127.0.0.1 \
  --dart-define=FREELOOM_DESKTOP_SERVER_PORT_START=9700 \
  --dart-define=FREELOOM_DESKTOP_SERVER_PORT_END=9710
```

## 4. 三端功能验收清单（MVP）

1. 桌面端 Flutter 登录成功。
2. 桌面授权页显示“已连接 desktop-server”。
3. 移动端登录后看到同账号设备列表（在线状态正确）。
4. 移动端点击连接：
   - 自动授权开时直接进入；
   - 自动授权关时桌面端出现授权请求。
5. 移动端远程查看页可：
   - 切换 480P / 720P / 1080P；
   - 切换自动码率；
   - 横竖屏切换；
   - 多屏列表切换；
   - 退后台 3 分钟后自动断开。

## 5. 常见问题排查

## 5.1 “Flutter App 缺少平台工程”

- 若你是在 `client/apps/mobile_app` 或 `client/apps/desktop_app` 目录直接 `flutter run`，会报平台相关错误，这是预期行为。
- 正确方式：在 `client/` 根目录运行并指定 `-t apps/.../main.dart`。

## 5.2 backend 正常但设备显示离线

- 检查 `desktop-server/config.toml` 的 `backend.device_id` 是否和注册设备一致。
- 检查 heartbeat 日志：`POST /api/v1/desktop/devices/{device_id}/heartbeat` 是否 2xx。

## 5.3 桌面端收不到授权弹窗

- 检查桌面 Flutter 是否已连接本地 WS（授权页状态）。
- 检查 `desktop-server` 是否订阅到 `session.requested`。

## 5.4 会话卡在连接中

- 检查 `coturn` 端口和 `APP__WEBRTC__ICE_SERVERS` 配置。
- 检查移动端/桌面端的 `webrtc.*` 事件是否都有往返。

## 6. 预发布与生产部署建议

## 6.1 backend-server（容器化）

- 使用 `backend-server/deploy/docker-compose.yml` 做预发布。
- 生产建议拆分：`postgres`、`redis`、`coturn` 使用独立高可用部署。
- backend 前置反向代理（TLS）。

## 6.2 desktop-server（主机部署）

- 以系统服务方式运行（macOS launchd / Windows Service）。
- 固定 `device_id` 和 backend 地址。
- 日志级别默认 `trace`，生产建议 `info`。

## 6.3 client（移动/桌面）

- 移动端按 Android/iOS 标准打包发布。
- 桌面端按 macOS/Windows 打包。
- 通过 `--dart-define` 统一注入环境（mock、api、desktop local ws）。

## 7. 可选：如果你希望每个 apps/* 都是独立 Flutter 平台工程

当前并非必须，但你可以在本机执行（仅一次）生成平台壳：

```bash
cd client/apps/mobile_app
flutter create . --platforms=android,ios --project-name mobile_app

cd ../desktop_app
flutter create . --platforms=macos,windows --project-name desktop_app
```

> 这属于工程形态选择，不影响当前“根壳工程 + 多入口”的运行方式。

## 8. 一键生成 apps 独立平台壳（可选）

如果你希望 `apps/mobile_app` 和 `apps/desktop_app` 都具备各自平台目录，可执行：

```bash
./scripts/bootstrap-client-platforms.sh
```

该脚本会在缺失时调用：

- `flutter create . --platforms=android,ios --project-name mobile_app`
- `flutter create . --platforms=macos,windows --project-name desktop_app`
