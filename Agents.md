# Agents Notes

## 任务相关
- 任务完成记得调用通知相关的MCP工具

## Backend Server Docker Compose 日志

- `backend-server/deploy/docker-compose.yml` 中，`backend-server` 服务将应用运行日志挂载到 `backend-server/deploy/runtime-logs/`（容器内路径 `/app/runtime-logs`）。
- 该目录下应保留 backend-server 的运行日志文件，可直接进入 `backend-server/deploy/runtime-logs/` 查看。
- Compose 容器标准输出日志可在 `backend-server/deploy/` 目录执行 `docker compose logs -f backend-server` 查看。
- 仓库根目录也提供了快捷脚本：`./scripts/dev-logs.sh backend-server`。
- `coturn` 额外配置了 `--log-file=stdout`，其日志走 `docker compose logs`，不是单独挂载文件目录。

## Flutter Client 非业务代码要求

- `client/` 下的 Flutter UI 状态管理统一使用 Riverpod，新增页面状态不得继续散落在大段 `setState` 中。
- Flutter 客户端采用 MVVM：`View` 负责渲染和绑定，`ViewModel` 负责交互动作与状态流转，`State` 保持不可变数据结构。
- UI 文件应按职责拆分；页面入口、表单区、装饰背景、弹层/卡片等应拆到独立文件或 `part` 文件，避免单文件持续膨胀。
- 非业务的通用壳层、响应式布局、桌面窗口适配、共享样式和基础交互，应优先沉淀到 `client/lib/src/` 或对应 package 的公共层，不要混入业务流程代码。
- Desktop 端必须支持不同窗口尺寸的自适应布局，避免依赖单一固定宽度；当前最小支持窗口尺寸为 `1100 x 720`。
- Desktop 页面在窄窗口下需要提供可降级布局，例如压缩头部、换行导航或收敛边距，不能因窗口缩小直接溢出。
