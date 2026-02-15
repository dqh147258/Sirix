# Freeloom Client

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

# 桌面端（macOS）
flutter run -t apps/desktop_app/lib/main.dart -d macos
```

## 推荐脚本（仓库根目录）

```bash
./scripts/run-mobile-client.sh
./scripts/run-desktop-client.sh -d macos
```

## 运行参数（--dart-define）

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

## 当前能力（MVP）

- 统一账号注册/登录（移动端与桌面端共用）。
- 移动端设备列表、连接请求、会话状态监听。
- 移动端远程查看：分辨率切换、自动码率、横竖屏切换、快照预览与多屏切换。
- 移动端退后台 3 分钟保活后自动断开。
- 桌面端授权页：自动授权开关、本地授权请求处理、与 desktop-server 实时联动。
