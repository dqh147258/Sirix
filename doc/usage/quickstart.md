# 开发与使用说明（MVP）

> 三端联调与部署完整版本见：`doc/deployment/three-end-debug-deploy.md`。

## 1. 本地开发前置条件

- Flutter SDK（建议 stable 最新）。
- Rust stable + Cargo。
- Docker + Docker Compose。
- Android/iOS 测试设备与 macOS/Windows 桌面环境。

## 2. 推荐启动顺序

1. 启动基础服务与 backend：`./scripts/dev-up.sh`
2. 启动 `desktop-server`：`cd desktop-server && cargo run`
3. 安装 Darwin 侧 Pod 依赖：
   - `cd client/ios && pod install`
   - `cd client/macos && pod install`
4. 启动 Flutter 桌面端：`cd client && flutter run -t apps/desktop_app/lib/main.dart -d macos`
5. 启动 Flutter 移动端：`cd client && flutter run -t apps/mobile_app/lib/main.dart`

实时日志：

- `./scripts/dev-logs.sh backend-server`
- `cd desktop-server && RUST_LOG=trace cargo run`

## 2.1 控制链路 Smoke 验证

在 `backend-server` 与 `desktop-server` 启动后，可运行：

```bash
./scripts/run-e2e-smoke.sh
```

当前该脚本会真实验证：

- 用户注册/登录
- 固定 `device_id` 设备注册
- 桌面本地 WS `settings.sync` / `authorize.request`
- 移动端事件流 `connection.request.accepted` / `webrtc.answer` / `session.state.changed`
- backend 信令转发
- 快照读取
- 会话暂停 / 恢复 / 终止

注意：

- 若本地库里残留旧数据导致固定 `device_id` 冲突，先执行 `./scripts/dev-reset.sh`。
- 执行 `./scripts/dev-reset.sh` 后，建议重新启动一次 `desktop-server`，避免 backend 重建期间事件订阅尚未恢复就发起连接。
- 该脚本当前验证的是控制链路与信令骨架；Flutter 端真实视频链路已接入 `flutter_webrtc`，但仍需在真实 macOS / iOS 设备上补做首帧与权限验证。

## 3. 关键配置对齐

## 3.1 desktop-server 与 backend 对齐

文件：`desktop-server/config.toml`

- `backend.base_url`
- `backend.device_id`
- `backend.event_ws_path`
- `backend.heartbeat_path`
- `backend.session_decision_path`
- `backend.webrtc_signal_path`

> 若通过 API 网关改了 backend 路由前缀，只需改上述 path 字段。

## 3.2 Flutter 客户端编译参数

`client/packages/infra_api/lib/src/providers.dart` 使用以下 `--dart-define`：

- `FREELOOM_USE_MOCK`（默认 `true`）
- `FREELOOM_SERVER_HOST`（默认 `192.168.0.36`，用于推导 backend 地址）
- `FREELOOM_API_BASE_URL`（默认空；未显式指定时自动使用 `http://${FREELOOM_SERVER_HOST}:8080`）
- `FREELOOM_DESKTOP_SERVER_HOST`（默认 `127.0.0.1`）
- `FREELOOM_DESKTOP_SERVER_PORT_START`（默认 `9700`）
- `FREELOOM_DESKTOP_SERVER_PORT_END`（默认 `9710`）

示例：

```bash
flutter run -t apps/mobile_app/lib/main.dart \
  --dart-define=FREELOOM_USE_MOCK=false \
  --dart-define=FREELOOM_SERVER_HOST=192.168.0.36
```

## 4. 用户流程（当前实现）

1. 桌面端登录后进入“授权”页，自动连接本地 `desktop-server`。
2. 桌面端通过 `settings.sync` 获得 `device_id`，并向 backend 进行设备注册/续活（幂等）。
3. 移动端登录后进入设备列表，查看同账号在线桌面设备。
4. 点击“连接”创建会话。
5. backend 将请求推送给 desktop-server：
   - 自动授权开启：直接批准。
   - 自动授权关闭：桌面端弹出授权请求，手动批准/拒绝。
6. 移动端进入远程查看页：
   - 已接入真实 RTC 视频渲染。
   - 支持 480P/720P/1080P 与自动码率。
   - 支持手动横竖屏切换。
   - 支持多屏选择与快照预览（默认 5 秒刷新，可改 3/5/10 秒）。
7. 移动端退后台后保持 3 分钟，超时自动断开（服务端也会兜底终止并广播 `session.auto_terminated`）。

## 5. 常见故障排查

- 设备离线：检查 `desktop-server` 心跳与 `backend.device_id` 是否正确。
- 桌面端无授权弹窗：检查桌面 Flutter 是否已连接 `desktop-server` 本地 WS。
- 自动授权设置不一致：检查桌面端是否已完成设备注册，并确认 `PATCH /devices/{id}/settings` 返回 2xx。
- 连接卡住：检查 `coturn` 端口映射、`APP__WEBRTC__ICE_SERVERS` 配置。
- 事件不同步：检查移动端是否使用了 `FREELOOM_USE_MOCK=false`。
- macOS / iOS 原生编译缺少 WebRTC：重新执行 `cd client/ios && pod install`、`cd client/macos && pod install`，确认 `Podfile.lock` 中出现 `flutter_webrtc`、`path_provider_foundation`、`WebRTC-SDK`。
