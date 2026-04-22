# Sirix

Sirix 是一个三部分协作的远程协助系统：

- `backend-server/`：Rust 控制平面，负责账号、设备、会话、事件流、WebRTC 信令。
- `desktop-server/`：Rust 桌面代理，负责本地桌面侧心跳、事件订阅、本地 WS、授权决策、信令转发。
- `client/`：Flutter 客户端，包含移动端与桌面端两个入口。

更细的设计和部署文档见 [doc/README.md](./doc/README.md)。

## 目录说明

```text
Sirix/
  backend-server/   # 后端服务
  desktop-server/   # 桌面后端服务
  client/           # Flutter 客户端（移动端 + 桌面端）
  scripts/          # 启停、日志、联调脚本
  doc/              # 架构、部署、使用说明
```

## 推荐启动顺序

1. 启动后端基础服务和 `backend-server`
2. 启动 `desktop-server`
3. 启动 Flutter 桌面端
4. 启动 Flutter 移动端

## 1. backend-server 如何使用

推荐方式是直接用根目录脚本：

```bash
./scripts/dev-up.sh
./scripts/dev-up.sh --clear-logs
./scripts/dev-up.sh --release
./scripts/dev-tui.sh
```

说明：

- 默认启动 Debug 场景；附带 `--release` 时切到 Release 场景。
- `--clear-logs` 会清理当前 scene 对应的 `backend-server/deploy/runtime-logs/<scene>/`，方便重新观察本轮联调日志。
- `dev-up.sh` / `dev-restart.sh` 默认不再强制 rebuild / pull；需要时再显式附带 `--build`、`--pull`。
- `dev-tui.sh` 提供一个统一的本地联调控制台，可并行启动/停止 backend、desktop-server、CLI build、desktop client、mobile client，并支持上下键回看历史指令、颜色状态、失败提示，以及按 `V` 查看最近失败任务日志。

查看后端日志：

```bash
./scripts/dev-logs.sh backend-server
```

停止后端服务：

```bash
./scripts/dev-down.sh
```

如果你要单独本地运行：

```bash
cd backend-server
CARGO_HOME=/tmp/cargo-home cargo run
```

详细说明见 [backend-server/README.md](./backend-server/README.md)。

## 2. desktop-server 如何使用

推荐脚本：

```bash
./scripts/run-desktop-server.sh
./scripts/run-desktop-server.sh --clear-logs
./scripts/run-desktop-server.sh --release
```

手动启动：

```bash
cd desktop-server
CARGO_HOME=/tmp/cargo-home cargo run
```

查看详细日志：

```bash
cd desktop-server
RUST_LOG=trace cargo run
```

配置文件：

```text
desktop-server/config.toml
```

默认重要配置（按 scene 派生）：

- Debug backend 地址：`http://127.0.0.1:46110`
- Release backend 地址：`http://127.0.0.1:46120`
- Debug 本地 WS 端口范围：`46111-46119`
- Release 本地 WS 端口范围：`46121-46129`
- 固定设备 ID：`00000000-0000-0000-0000-000000000001`

详细说明见 [desktop-server/README.md](./desktop-server/README.md)。

## 3. client 如何使用

客户端是单 Flutter 壳工程 + 双入口：

- 移动端入口：`client/apps/mobile_app/lib/main.dart`
- 桌面端入口：`client/apps/desktop_app/lib/main.dart`

不要在 `apps/*` 子目录直接运行 `flutter run`，应当始终在 `client/` 根目录运行。

### 3.1 移动端

推荐脚本：

```bash
./scripts/run-mobile-client.sh
```

手动运行：

```bash
cd client
flutter run -t apps/mobile_app/lib/main.dart \
  --dart-define=SIRIX_USE_MOCK=false
```

当前移动端默认后端地址会指向：

```text
http://192.168.0.36:<scene-port>
```

其中 Debug 为 `46110`，Release 为 `46120`。

若只想切换服务主机地址：

```bash
cd client
flutter run -t apps/mobile_app/lib/main.dart \
  --dart-define=SIRIX_SCENE=debug \
  --dart-define=SIRIX_USE_MOCK=false \
  --dart-define=SIRIX_SERVER_HOST=192.168.0.50
```

若要直接指定完整 API 地址：

```bash
cd client
flutter run -t apps/mobile_app/lib/main.dart \
  --dart-define=SIRIX_SCENE=debug \
  --dart-define=SIRIX_USE_MOCK=false \
  --dart-define=SIRIX_API_BASE_URL=http://192.168.0.50:46110
```

### 3.2 桌面端

首次在 Darwin 平台运行前建议先安装 Pod：

```bash
cd client/ios && pod install
cd client/macos && pod install
```

推荐脚本：

```bash
./scripts/run-desktop-client.sh
```

手动运行：

```bash
cd client
flutter run -t apps/desktop_app/lib/main.dart -d macos \
  --dart-define=SIRIX_SCENE=debug \
  --dart-define=SIRIX_USE_MOCK=false \
  --dart-define=SIRIX_API_BASE_URL=http://127.0.0.1:46110 \
  --dart-define=SIRIX_DESKTOP_SERVER_HOST=127.0.0.1 \
  --dart-define=SIRIX_DESKTOP_SERVER_PORT_START=46111 \
  --dart-define=SIRIX_DESKTOP_SERVER_PORT_END=46119
```

Linux 手动运行：

```bash
cd client
flutter run -t apps/desktop_app/lib/main.dart -d linux \
  --dart-define=SIRIX_SCENE=debug \
  --dart-define=SIRIX_USE_MOCK=false \
  --dart-define=SIRIX_API_BASE_URL=http://127.0.0.1:46110 \
  --dart-define=SIRIX_DESKTOP_SERVER_HOST=127.0.0.1 \
  --dart-define=SIRIX_DESKTOP_SERVER_PORT_START=46111 \
  --dart-define=SIRIX_DESKTOP_SERVER_PORT_END=46119
```

说明：

- `SIRIX_SCENE` 控制 Debug / Release 默认值
- `SIRIX_SERVER_HOST` 主要用于移动端推导 backend 地址
- `SIRIX_DESKTOP_SERVER_HOST` 用于连接本地 `desktop-server`
- 本地桌面代理默认仍应保持 `127.0.0.1`
- `./scripts/run-desktop-client.sh` 不传 `-d` 时会按宿主机自动选择 `macos` 或 `linux`
- `./scripts/run-mobile-client.sh`、`./scripts/run-desktop-client.sh` 默认走 Debug；附带脚本级 `--release` 则切到 Release scene
- 上述两个脚本都支持 `--clear-logs`，会先清理当前 scene 对应的 backend runtime logs，再启动 Flutter

详细说明见 [client/README.md](./client/README.md)。

## 联调命令

三端启动后，可用下面的脚本做控制链路 smoke：

```bash
./scripts/run-e2e-smoke.sh
```

如果旧数据导致固定 `device_id` 冲突，可先执行：

```bash
./scripts/dev-reset.sh
```

然后把 `desktop-server` 重启一次。

## 文档入口

- 总文档索引：[doc/README.md](./doc/README.md)
- 快速使用：[doc/usage/quickstart.md](./doc/usage/quickstart.md)
- 三端联调与部署：[doc/deployment/three-end-debug-deploy.md](./doc/deployment/three-end-debug-deploy.md)
- 后续待办：[doc/TODO.md](./doc/TODO.md)
