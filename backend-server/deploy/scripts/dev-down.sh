#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
source "${DEPLOY_DIR}/../../scripts/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)

usage() {
  cat <<'EOF'
Usage: ./backend-server/deploy/scripts/dev-down.sh [--release]

Options:
  --release      Use the Release Sirix scene.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      SCENE=release
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

cd "${DEPLOY_DIR}"
docker compose \
  --env-file "$(sirix_compose_env_file_for_scene "${DEPLOY_DIR}" "${SCENE}")" \
  -f docker-compose.yml \
  down
