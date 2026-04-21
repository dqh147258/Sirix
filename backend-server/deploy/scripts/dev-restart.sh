#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
source "${DEPLOY_DIR}/../../scripts/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)
RESET_DATA=false
EXPOSE_DEPS=false
CLEAR_LOGS=false

usage() {
  cat <<'EOF'
Usage: ./backend-server/deploy/scripts/dev-restart.sh [--release] [--expose-deps] [--clear-logs] [--reset-data]

Options:
  --release      Use the Release Sirix scene.
  --expose-deps  Publish Postgres/Redis/Coturn host ports for the chosen scene.
  --clear-logs   Clear backend runtime logs for the chosen scene before startup.
  --reset-data   Restart and recreate compose volumes. This deletes local dev data.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      SCENE=release
      shift
      ;;
    --expose-deps)
      EXPOSE_DEPS=true
      shift
      ;;
    --clear-logs)
      CLEAR_LOGS=true
      shift
      ;;
    --reset-data)
      RESET_DATA=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

sirix_export_scene_env "${SCENE}" "${DEPLOY_DIR}"
mkdir -p "${RUNTIME_LOGS_HOST_DIR}"
if [[ "${CLEAR_LOGS}" == true ]]; then
  sirix_clear_runtime_logs_for_scene "${DEPLOY_DIR}" "${SCENE}"
fi

if [[ "${EXPOSE_DEPS}" == true ]]; then
  sirix_export_dependency_host_ports "${SCENE}"
fi

compose_args=(
  docker compose
  --env-file "$(sirix_compose_env_file_for_scene "${DEPLOY_DIR}" "${SCENE}")"
  -f docker-compose.yml
)
if [[ "${EXPOSE_DEPS}" == true ]]; then
  compose_args+=(-f docker-compose.deps.yml)
fi

cd "${DEPLOY_DIR}"
if [[ "${RESET_DATA}" == true ]]; then
  "${compose_args[@]}" down -v
else
  "${compose_args[@]}" down
fi

compose_up_log="$(mktemp)"
cleanup() {
  rm -f "${compose_up_log}"
}
trap cleanup EXIT

if ! "${compose_args[@]}" up -d --build 2>&1 | tee "${compose_up_log}"; then
  if grep -Eqi 'docker\.mirrors\.ustc\.edu\.cn|registry-mirrors|failed to do request: Head .*docker\.io.*EOF' "${compose_up_log}"; then
    cat >&2 <<'EOF'

Detected a Docker registry mirror failure from the local Docker daemon configuration.
Your Docker daemon is trying to pull docker.io images through a mirror that is currently unavailable.

Recommended fix on this machine:
  1. Open ~/.docker/daemon.json or Docker Desktop -> Settings -> Docker Engine
  2. Remove the broken "registry-mirrors" entries, especially:
       https://docker.mirrors.ustc.edu.cn
       https://hub-mirror.c.163.com
       https://registry.docker-cn.com
  3. Restart Docker Desktop
  4. Retry:
       ./backend-server/deploy/scripts/dev-restart.sh
EOF
  fi
  exit 1
fi

"${compose_args[@]}" ps

backend_container_id="$("${compose_args[@]}" ps -aq backend-server)"
if [[ -z "${backend_container_id}" ]]; then
  echo "backend-server container was not created" >&2
  exit 1
fi

deadline=$((SECONDS + 15))
while ((SECONDS < deadline)); do
  backend_status="$(docker inspect -f '{{.State.Status}}' "${backend_container_id}")"
  case "${backend_status}" in
    running)
      exit 0
      ;;
    exited|dead)
      break
      ;;
  esac
  sleep 1
done

backend_status="$(docker inspect -f '{{.State.Status}}' "${backend_container_id}")"
if [[ "${backend_status}" != "running" ]]; then
  echo "backend-server failed to stay running (status: ${backend_status})" >&2
  backend_logs="$("${compose_args[@]}" logs --no-color --tail=100 backend-server || true)"
  if [[ -n "${backend_logs}" ]]; then
    printf '%s\n' "${backend_logs}" >&2
  fi
  exit 1
fi
