# Sirix 远程协助系统文档

本文档集合覆盖本仓库的第一阶段（MVP）架构设计与落地约束。

## 文档索引

- 架构设计：`doc/architecture/system-architecture.md`
- 接口与协议：`doc/architecture/api-contracts.md`
- 部署与运维：`doc/deployment/docker-compose.md`
- 三端联调与部署（独立）：`doc/deployment/three-end-debug-deploy.md`
- 开发与使用：`doc/usage/quickstart.md`
- 后续待办：`doc/TODO.md`

## MVP 范围（当前阶段）

- 支持账号密码注册/登录（开放注册）。
- 支持同账号下：移动端查看桌面端设备列表并发起屏幕共享。
- 支持桌面端设备级自动授权开关（默认关闭），并与 backend 设备设置同步。
- 支持固定 `device_id` 的设备幂等注册（用于 desktop-server/Flutter 桌面端一致性）。
- 支持多屏选择与快照预览（默认 5 秒刷新，低分辨率缩略图）。
- 支持分辨率手动切换与动态分辨率自动调整。
- 支持移动端观看页手动横竖屏切换。
- 支持移动端退后台后维持会话 3 分钟，后端执行超时兜底终止。

## 非目标（本阶段）

- 鼠标/键盘远控。
- 跨账号协助流程的完整产品化（仅预留数据模型与鉴权扩展位）。
- TURN TLS(443) 与企业网络强兼容方案（记录于 `doc/TODO.md`）。
