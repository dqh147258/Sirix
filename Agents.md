# Agents Notes

## Backend Server Docker Compose 日志

- `backend-server/deploy/docker-compose.yml` 中，`backend-server` 服务将应用运行日志挂载到 `backend-server/deploy/runtime-logs/`（容器内路径 `/app/runtime-logs`）。
- 该目录下应保留 backend-server 的运行日志文件，可直接进入 `backend-server/deploy/runtime-logs/` 查看。
- Compose 容器标准输出日志可在 `backend-server/deploy/` 目录执行 `docker compose logs -f backend-server` 查看。
- 仓库根目录也提供了快捷脚本：`./scripts/dev-logs.sh backend-server`。
- `coturn` 额外配置了 `--log-file=stdout`，其日志走 `docker compose logs`，不是单独挂载文件目录。
