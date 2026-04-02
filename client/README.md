# Sirix Client

Flutter 客户端采用 Melos 多模块组织，分移动端与桌面端双入口。

## 目录结构

```text
client/
  android/ ios/ macos/ windows/ ...   # 平台壳工程（统一）
  apps/
    mobile_app/                       # 移动端入口模块
    desktop_app/                      # 桌面端入口模块
  packages/
    app_core/
    infra_api/
    infra_webrtc/
    feature_auth/
    feature_device_list/
    feature_remote_view/
    feature_desktop_authorize/
```

## 重要说明（避免误操作）

- `apps/mobile_app` 和 `apps/desktop_app` 是入口模块，不是独立平台工程。
- 请在 `client/` 根目录运行 `flutter run -t apps/.../main.dart`。
- 不建议在 `apps/*` 子目录直接 `flutter run`。

## 架构

- 状态管理：Riverpod
- 模式：MVVM（View + ViewModel + State）
- 共享层：`app_core` + `infra_*`
- 业务层：`feature_*`

## 常用命令

```bash
cd client
melos bootstrap

# 移动端
flutter run -t apps/mobile_app/lib/main.dart

# 桌面端（macOS / Linux）
flutter run -t apps/desktop_app/lib/main.dart -d macos
flutter run -t apps/desktop_app/lib/main.dart -d linux
```

## 推荐脚本（仓库根目录）

```bash
./scripts/run-mobile-client.sh
./scripts/run-desktop-client.sh
```

说明：

- `./scripts/run-desktop-client.sh` 未显式传 `-d` 时，会按宿主机自动补 `-d macos` 或 `-d linux`。
- Linux 首次使用前，请确认 `flutter config --enable-linux-desktop` 已开启。

## 运行参数（--dart-define）

- `SIRIX_USE_MOCK`（默认 `true`）
- `SIRIX_SERVER_HOST`（默认 `192.168.0.36`，用于推导 backend 地址）
- `SIRIX_API_BASE_URL`（默认空；未显式指定时自动使用 `http://${SIRIX_SERVER_HOST}:8080`）
- `SIRIX_DESKTOP_SERVER_HOST`（默认 `127.0.0.1`）
- `SIRIX_DESKTOP_SERVER_PORT_START`（默认 `9700`）
- `SIRIX_DESKTOP_SERVER_PORT_END`（默认 `9710`）

说明：

- 移动端默认会把 backend 指向 `192.168.0.36:8080`。
- 若只想切换后端主机地址，优先传 `SIRIX_SERVER_HOST`。
- 若需要完整覆盖协议、端口或路径，再直接传 `SIRIX_API_BASE_URL`。

示例：

```bash
flutter run -t apps/mobile_app/lib/main.dart \
  --dart-define=SIRIX_USE_MOCK=false \
  --dart-define=SIRIX_SERVER_HOST=192.168.0.36
```

显式指定完整地址：

```bash
flutter run -t apps/mobile_app/lib/main.dart \
  --dart-define=SIRIX_USE_MOCK=false \
  --dart-define=SIRIX_API_BASE_URL=http://192.168.0.36:8080
```

## 当前能力（MVP）

- 统一账号注册/登录（移动端与桌面端共用）。
- 移动端设备列表、连接请求、会话状态监听。
- 移动端远程查看：分辨率切换、自动码率、横竖屏切换、快照预览与多屏切换。
- 移动端退后台 3 分钟保活后自动断开（后端也会执行超时兜底终止）。
- 桌面端授权页：
- 自动连接 desktop-server 本地 WS。
- 展示并使用 desktop-server 下发的 `device_id`。
- 用固定 `device_id` 向 backend 注册设备（幂等更新）。
- 设备注册会按当前桌面系统上报 `macos`、`linux` 或 `windows`。
- 自动授权开关与 backend 设备设置双向同步。
