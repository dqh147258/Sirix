# Debug / Release 共存隔离

## 本次做了什么

为 Sirix 增加 Debug / Release 场景隔离，避免 Debug 开发时污染 Release 使用环境。

核心能力：

1. **Scene 约定统一**
   - 默认 `debug`
   - `--release` 切到 `release`

2. **全局目录隔离**
   - Debug: `~/.sirix-debug`
   - Release: `~/.sirix`

3. **工作区目录隔离**
   - Debug: `<workspace>/.sirix-debug`
   - Release: `<workspace>/.sirix`

4. **默认端口隔离**
   - Debug:
     - Backend API `46110`
     - Desktop local WS `46111-46119`
   - Release:
     - Backend API `46120`
     - Desktop local WS `46121-46129`

5. **运行态隔离**
   - `sirix-runtime` 不再允许 debug/release 串用
   - desktop/mobile auth session 按 scene 隔离
   - compose project / runtime logs / host exposed deps 按 scene 隔离
   - 启动脚本支持 `--clear-logs`，方便在调试前清空 scene 对应的 backend runtime logs

## 主要实现文件

### scripts / compose

- `scripts/lib/sirix-scene.sh`
  - 统一维护 scene 默认值（home、workspace dirname、端口、compose project、deps host ports）
- `scripts/dev-*.sh`
  - 改为薄代理到 deploy scripts，避免两套逻辑漂移
- `backend-server/deploy/scripts/dev-*.sh`
  - 增加 scene 感知、`--release`、`--expose-deps`
  - `dev-up.sh` / `dev-restart.sh` 支持 `--clear-logs`
  - `dev-up.sh` / `dev-restart.sh` 默认不再强制 rebuild / pull，必要时再显式 `--build` / `--pull`
- `scripts/run-desktop-server.sh`
  - scene-aware 构建并启动 `desktop-server` / `sirix` / `sirix-runtime`
- `scripts/run-desktop-client.sh`
- `scripts/run-mobile-client.sh`
- `scripts/run-client.sh`
  - 支持 `--clear-logs`，启动前清理 scene 对应的 backend runtime logs
- `scripts/build-sirix-cli.sh`
  - 兼容原 positional `debug|release`，同时支持 `--release`
- `scripts/run-e2e-smoke.sh`
  - scene-aware 默认 API / desktop WS 地址
- `scripts/dev-tui.sh`
  - 统一管理 backend / desktop-server / CLI build / desktop client / mobile client
  - 支持并行启停、状态查看、冲突检测、日志清理、全开全关、移动端缺席自动跳过
  - 支持上下键回看历史输入指令
  - 支持状态/操作颜色区分，并在脚本失败时直接显示失败状态与说明
  - 支持列出最近失败的 10 个任务，并按序号查看对应日志快照
- `backend-server/deploy/docker-compose.yml`
  - 去掉固定 compose project name
  - runtime logs host 路径改为 scene-aware
- `backend-server/deploy/docker-compose.deps.yml`
  - 只在 `--expose-deps` 时暴露 Postgres / Redis / Coturn host 端口
- `backend-server/deploy/.env.debug`
- `backend-server/deploy/.env.release`

### desktop-server

- `desktop-server/src/scene.rs`
  - 统一 Rust 侧 scene 解析与默认值
- `desktop-server/src/bootstrap/config.rs`
  - 增加 deterministic config discovery
  - shared `config.toml` + scene defaults + env override 叠加
- `desktop-server/config.toml`
  - 改成 scene-neutral baseline
- `desktop-server/src/cli_support.rs`
  - autostart 传递 `SIRIX_SCENE`
  - desktop probe 端口改为 scene-aware
- `desktop-server/src/app/ai/config.rs`
  - global home / workspace dir / recent workspace / bin shim / legacy migration 改为 scene-aware
- `desktop-server/src/app/terminal/manager.rs`
  - `sirix-runtime` 解析按当前 scene/profile 严格匹配
- `desktop-server/src/app/auth.rs`
- `desktop-server/src/app/state.rs`
  - desktop auth session 文件移动到 `<sirix_home>/runtime/auth-session.json`
- `desktop-server/src/bin/sirix-terminal.rs`
  - hosted shell 继承 scene-aware `SIRIX_HOME` / `SIRIX_SCENE`
- `backend-server/src/application/runtime_logging.rs`
  - 运行中如果 `runtime-logs/<scene>` 被清理，会自动重建目录后继续写入，避免日志写入失败

### client / docs

- `client/packages/infra_api/lib/src/providers.dart`
  - scene-aware backend 与 desktop local 默认值
- `client/packages/feature_auth/lib/src/auth_session_store.dart`
  - auth session 文件按 scene 隔离
- `client/packages/feature_settings_ai/lib/src/*`
  - `.sirix-debug` / `.sirix` UI 文案与 workspace 识别
- `README.md`
- `client/README.md`
- `desktop-server/README.md`
- `doc/deployment/three-end-debug-deploy.md`

## 采用的方法

采用 **Thin Scene Defaults Adapter**：

- 显式配置优先
- scene 只补默认值
- 不新增完整独立配置体系

这样可以在保持现有 `SIRIX_HOME`、`DESKTOP__...`、`APP__...`、Flutter `--dart-define` 兼容性的前提下，把 Debug / Release 的默认运行面彻底拆开。
