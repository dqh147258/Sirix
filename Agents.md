# Agents Notes

## 任务相关
- 任务完成记得调用通知相关的MCP工具

## Backend Server Docker Compose 日志

- `backend-server/deploy/docker-compose.yml` 中，`backend-server` 服务将应用运行日志挂载到 `backend-server/deploy/runtime-logs/`（容器内路径 `/app/runtime-logs`）。
- 该目录下应保留 backend-server 的运行日志文件，可直接进入 `backend-server/deploy/runtime-logs/` 查看。
- Compose 容器标准输出日志可在 `backend-server/deploy/` 目录执行 `docker compose logs -f backend-server` 查看。
- 仓库根目录也提供了快捷脚本：`./scripts/dev-logs.sh backend-server`。
- `coturn` 额外配置了 `--log-file=stdout`，其日志走 `docker compose logs`，不是单独挂载文件目录。

## 日志添加约定

- 需要新增日志时，优先复用各端现有日志入口，不要临时直接 `print`、`debugPrint`、`println!` 后就结束，除非只是一次性本地调试且不会提交。
- 新增日志默认要考虑是否能进入现有 runtime logs 链路，便于通过 backend-server 统一检索。
- 日志前缀建议使用稳定的专题前缀，例如 `[TERMINAL_INPUT_TRACE]`、`[MEDIA_AUTH_TRACE]`，便于按问题域检索，不要使用随意字符串。
- 日志内容应尽量带关键上下文，例如 `session_id`、`terminal_id`、`device_id`、当前 transport、关键状态值；避免只写“进入这里了”这类低价值信息。
- 涉及高频链路时，优先只记录控制类事件、状态变化、错误分支和关键边界点，避免把普通数据流全量打满。

### backend-server

- Rust backend-server 的应用日志优先沿现有服务日志体系输出，保持可进入 `backend-server/deploy/runtime-logs/` 或 `docker compose logs`。
- 若是请求链路、状态机、后台任务相关日志，优先复用 backend-server 当前模块内已有的日志风格与入口，不要额外再造一套 logger 抽象。
- 新增日志时尽量放在边界点：请求进入、关键分支、外部服务调用结果、状态落库前后、错误返回前。

### desktop-server

- desktop-server 需要上报到 backend-server 的运行日志时，优先使用 `desktop-server/src/app/runtime_logger.rs` 提供的 `RuntimeLogger`，不要只写到本地 stdout。
- `RuntimeLogger` 适合记录需要跨端排查的问题链路，例如本地 WS、PTY 输入输出、AI session 生命周期、desktop 本地授权流程。
- 若日志只对本机开发期有意义且不需要进入 backend runtime logs，可保留 `tracing`/stdout，但提交前应优先评估是否应该改为 `RuntimeLogger`。

### Flutter Client

- Flutter Client 需要进入 backend runtime logs 的日志，统一使用 `client/packages/app_core/lib/src/logging/app_logger.dart` 中的 `AppLogger`。
- `AppLogger` 适合记录桌面端和移动端都可能需要远程回看的事件，例如终端输入链路、WebRTC 会话状态、授权弹窗流程、设置页保存结果。
- Flutter UI 层不要直接散落 `debugPrint` 作为正式日志；提交代码时若日志需要保留，应改成 `AppLogger.info/warn/error`。
- View 层日志应聚焦用户交互入口和组件边界，ViewModel 层日志应聚焦状态流转、请求发送、事件接收与错误分支。

### 临时 Trace

- 为排查复杂链路临时增加 trace 时，应在文档或注释中注明专题前缀、入口文件和日志目的，避免后续难以区分是否可删除。
- 临时 trace 如果会长期保留，应收敛为稳定的专题日志；如果只用于一次排查，问题关闭后应主动清理。

## Flutter Client 非业务代码要求

- `client/` 下的 Flutter UI 状态管理统一使用 Riverpod，新增页面状态不得继续散落在大段 `setState` 中。
- Flutter 客户端采用 MVVM：`View` 负责渲染和绑定，`ViewModel` 负责交互动作与状态流转，`State` 保持不可变数据结构。
- UI 文件应按职责拆分；页面入口、表单区、装饰背景、弹层/卡片等应拆到独立文件或 `part` 文件，避免单文件持续膨胀。
- 非业务的通用壳层、响应式布局、桌面窗口适配、共享样式和基础交互，应优先沉淀到 `client/lib/src/` 或对应 package 的公共层，不要混入业务流程代码。
- Desktop 端必须支持不同窗口尺寸的自适应布局，避免依赖单一固定宽度；当前最小支持窗口尺寸为 `1100 x 720`。
- Desktop 页面在窄窗口下需要提供可降级布局，例如压缩头部、换行导航或收敛边距，不能因窗口缩小直接溢出。
