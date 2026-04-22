#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
source "${DEPLOY_DIR}/../../scripts/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)
EXPOSE_DEPS=false
CLEAR_LOGS=false
FORCE_BUILD=false
FORCE_PULL=false

usage() {
  cat <<'EOF'
Usage: ./backend-server/deploy/scripts/dev-up.sh [--release] [--expose-deps] [--clear-logs] [--build] [--pull]

Options:
  --release      Use the Release Sirix scene.
  --expose-deps  Publish Postgres/Redis/Coturn host ports for the chosen scene.
  --clear-logs   Clear backend runtime logs for the chosen scene before startup.
  --build        Force rebuilding the backend-server image before startup.
  --pull         Explicitly pull dependency images / newer base layers before startup.
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
    --build)
      FORCE_BUILD=true
      shift
      ;;
    --pull)
      FORCE_PULL=true
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
if [[ "${FORCE_PULL}" == true ]]; then
  # 默认联调不主动走网络，只有显式要求时才刷新依赖镜像或 backend 构建基底。
  "${compose_args[@]}" pull postgres redis coturn
fi

if [[ "${FORCE_BUILD}" == true ]]; then
  build_args=("${compose_args[@]}" build)
  if [[ "${FORCE_PULL}" == true ]]; then
    build_args+=(--pull)
  fi
  build_args+=(backend-server)
  "${build_args[@]}"
fi

"${compose_args[@]}" up -d
"${compose_args[@]}" ps
