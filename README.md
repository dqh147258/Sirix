# Sirix

Sirix 是一个三部分协作的远程协助与 AI 终端系统：

- `backend-server/`：Rust 控制平面，负责账号、设备、会话、事件流、WebRTC 信令。
- `desktop-server/`：Rust 桌面代理，负责本地桌面侧心跳、事件订阅、本地 WS、授权决策、信令转发，并承载 Sirix AI / Terminal 本地运行时。
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
3. 启动 Flutter 桌面端或移动端
4. 按需使用 `sirix` / `sirix-terminal`

日常联调可以直接使用统一控制台：

```bash
./scripts/dev-tui.sh
./scripts/dev-tui.sh --release
```

`dev-tui.sh` 可以统一管理 backend、desktop-server、CLI build、desktop client、mobile client 的启动/停止/重启、状态查看、日志清理和失败任务日志查看。

## Debug / Release scene

脚本默认使用 Debug scene；脚本级 `--release` 会切到 Release scene。两套 scene 会隔离端口、配置目录和运行日志。

| 项目 | Debug | Release |
| --- | --- | --- |
| 全局配置目录 | `~/.sirix-debug` | `~/.sirix` |
| 工作区配置目录 | `<workspace>/.sirix-debug` | `<workspace>/.sirix` |
| backend 端口 | `46110` | `46120` |
| desktop-server 本地 WS 端口段 | `46111-46119` | `46121-46129` |
| 固定设备 ID | `00000000-0000-0000-0000-000000000101` | `00000000-0000-0000-0000-000000000001` |

如果需要暴露 Docker 依赖端口，`./scripts/dev-up.sh --expose-deps` 会按 scene 发布 Postgres、Redis、Coturn 端口。Debug 默认是 `46210-46218`，Release 默认是 `46220-46228`。

## 1. backend-server 如何使用

推荐方式是直接用根目录脚本：

```bash
./scripts/dev-up.sh
./scripts/dev-up.sh --clear-logs
./scripts/dev-up.sh --release
./scripts/dev-up.sh --expose-deps
```

说明：

- 默认启动 Debug 场景；附带 `--release` 时切到 Release 场景。
- `--clear-logs` 会清理当前 scene 对应的 `backend-server/deploy/runtime-logs/<scene>/`，方便重新观察本轮联调日志。
- `--expose-deps` 会额外发布 Postgres / Redis / Coturn 的宿主机端口，便于本机工具直连依赖。
- `dev-up.sh` / `dev-restart.sh` 默认不再强制 rebuild / pull；需要时再显式附带 `--build`、`--pull`。
- `dev-restart.sh --reset-data` 或 `dev-reset.sh` 会删除当前 scene 的 Compose volumes，本地开发数据会被清空。

查看后端日志：

```bash
./scripts/dev-logs.sh backend-server
```

停止后端服务：

```bash
./scripts/dev-down.sh
./scripts/dev-down.sh --release
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
./scripts/run-desktop-server.sh --background
```

`run-desktop-server.sh` 会先构建 `desktop-server`、`sirix`、`sirix-terminal` 和 `sirix-runtime`，然后把 scene-aware shim 安装到当前 scene 的 `${SIRIX_HOME}/bin`：

```text
~/.sirix-debug/bin/   # Debug scene
~/.sirix/bin/         # Release scene
```

建议把当前使用的 scene bin 目录加入 `PATH`：

```bash
export PATH="$HOME/.sirix-debug/bin:$PATH"
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
- Debug 固定设备 ID：`00000000-0000-0000-0000-000000000101`
- Release 固定设备 ID：`00000000-0000-0000-0000-000000000001`

详细说明见 [desktop-server/README.md](./desktop-server/README.md)。

## 3. sirix CLI 与 sirix-terminal

`sirix` 和 `sirix-terminal` 是由 `desktop-server` 工作区构建出来的两个本地命令：

- `sirix`：启动 Sirix AI coding session，并把会话镜像到 Sirix Desktop / Mobile。
- `sirix list`：列出本机 desktop-server 当前记录的 AI sessions。
- `sirix resume <ai_session_id|terminal_id>`：从系统 Terminal 重新附着到已有 AI session。
- `sirix-terminal`：在系统 Terminal 中启动一个共享 shell PTY，Sirix Desktop / Mobile 可以同步查看和输入。

构建安装：

```bash
./scripts/build-sirix-cli.sh
./scripts/build-sirix-cli.sh --release
```

`./scripts/run-desktop-server.sh` 也会自动完成同样的 CLI 构建和 shim 安装。安装后的命令位于当前 scene 的 `SIRIX_HOME/bin`，shim 会注入 `SIRIX_SCENE` 和 `SIRIX_HOME`，避免 Debug / Release 配置串用。

使用前需要：

1. backend 已启动：`./scripts/dev-up.sh`
2. desktop-server 已启动或可被 CLI 自动拉起
3. 当前 scene 的 `SIRIX_HOME/bin` 已加入 `PATH`

示例：

```bash
sirix
sirix list
sirix resume <ai_session_id>
sirix-terminal
```

说明：

- `sirix` 启动时会探测本地 desktop-server；如果未运行，会尝试启动同目录下的 `desktop-server`。
- 若当前未登录，CLI 会提示输入用户名和密码；登录失败时可选择注册并继续。
- `sirix` 在普通系统 Terminal 中运行时，会在当前终端附着并交互；在已有 Sirix-managed terminal 中运行时，可按服务端策略复用当前 terminal；在 `sirix-terminal` 创建的 hosted shell 中运行时，会改为创建独立 AI session，并提示从 Desktop / Mobile 或系统 Terminal resume。
- `sirix resume` 不允许在 `sirix-terminal` hosted shell 内执行，避免嵌套附着。
- `sirix-terminal` 会启动一个子 shell：Windows 优先 `pwsh` / `powershell.exe` / `cmd.exe`，macOS 默认 `/bin/zsh`，Linux 默认 `$SHELL` 或 `/bin/bash`。

## 4. client 如何使用

客户端是单 Flutter 壳工程 + 双入口：

- 移动端入口：`client/apps/mobile_app/lib/main.dart`
- 桌面端入口：`client/apps/desktop_app/lib/main.dart`

不要在 `apps/*` 子目录直接运行 `flutter run`，应当始终在 `client/` 根目录运行。

### 4.1 移动端

推荐脚本：

```bash
./scripts/run-mobile-client.sh
./scripts/run-mobile-client.sh --update-deps
./scripts/run-mobile-client.sh -- --profile
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

### 4.2 桌面端

首次在 Darwin 平台运行前建议先安装 Pod：

```bash
cd client/ios && pod install
cd client/macos && pod install
```

推荐脚本：

```bash
./scripts/run-desktop-client.sh
./scripts/run-desktop-client.sh --update-deps
./scripts/run-desktop-client.sh -- -d macos
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
- Flutter 自身的 `--release`、`--profile`、`-d` 等参数需要放在脚本分隔符 `--` 之后。

详细说明见 [client/README.md](./client/README.md)。

### 4.3 交互式选择客户端

如果不确定当前应该启动移动端还是桌面端，可以使用：

```bash
./scripts/run-client.sh
./scripts/run-client.sh --list
./scripts/run-client.sh --release -- --profile
```

该脚本会读取 `flutter devices --machine`，按设备类型选择 `run-mobile-client.sh` 或 `run-desktop-client.sh`，并把脚本分隔符 `--` 之后的参数继续传给 `flutter run`。

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
