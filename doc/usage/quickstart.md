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
3. 启动 Flutter 桌面端：`cd client && flutter run -t apps/desktop_app/lib/main.dart -d macos`
4. 启动 Flutter 移动端：`cd client && flutter run -t apps/mobile_app/lib/main.dart`

实时日志：

- `./scripts/dev-logs.sh backend-server`
- `cd desktop-server && RUST_LOG=trace cargo run`

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
- `FREELOOM_API_BASE_URL`（默认 `http://127.0.0.1:8080`）
- `FREELOOM_DESKTOP_SERVER_HOST`（默认 `127.0.0.1`）
- `FREELOOM_DESKTOP_SERVER_PORT_START`（默认 `9700`）
- `FREELOOM_DESKTOP_SERVER_PORT_END`（默认 `9710`）

示例：

```bash
flutter run -t apps/mobile_app/lib/main.dart \
  --dart-define=FREELOOM_USE_MOCK=false \
  --dart-define=FREELOOM_API_BASE_URL=http://127.0.0.1:8080
```

## 4. 用户流程（当前实现）

1. 桌面端登录后进入“授权”页，自动连接本地 `desktop-server`。
2. 移动端登录后进入设备列表，查看同账号在线桌面设备。
3. 点击“连接”创建会话。
4. backend 将请求推送给 desktop-server：
   - 自动授权开启：直接批准。
   - 自动授权关闭：桌面端弹出授权请求，手动批准/拒绝。
5. 移动端进入远程查看页：
   - 支持 480P/720P/1080P 与自动码率。
   - 支持手动横竖屏切换。
   - 支持多屏选择与快照预览（默认 5 秒刷新，可改 3/5/10 秒）。
6. 移动端退后台后保持 3 分钟，超时自动断开。

## 5. 常见故障排查

- 设备离线：检查 `desktop-server` 心跳与 `backend.device_id` 是否正确。
- 桌面端无授权弹窗：检查桌面 Flutter 是否已连接 `desktop-server` 本地 WS。
- 连接卡住：检查 `coturn` 端口映射、`APP__WEBRTC__ICE_SERVERS` 配置。
- 事件不同步：检查移动端是否使用了 `FREELOOM_USE_MOCK=false`。
