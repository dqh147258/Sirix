#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)
TMP_DIR=${SIRIX_E2E_TMP_DIR:-/tmp/sirix-e2e}
CACHE_DIR=${SIRIX_E2E_NPM_CACHE:-/tmp/npm-cache}

usage() {
  cat <<'EOF'
Usage: ./scripts/run-e2e-smoke.sh [--release]

Options:
  --release      Use the Release Sirix scene defaults.
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

sirix_export_scene_env "${SCENE}"

mkdir -p "${TMP_DIR}" "${CACHE_DIR}"
npm_config_cache="${CACHE_DIR}" npm install --prefix "${TMP_DIR}" ws >/dev/null

export SIRIX_API_BASE_URL="${SIRIX_API_BASE_URL:-http://127.0.0.1:$(sirix_backend_port_for_scene "${SCENE}")}"
export SIRIX_DESKTOP_LOCAL_WS_URL="${SIRIX_DESKTOP_LOCAL_WS_URL:-ws://127.0.0.1:$(sirix_desktop_port_start_for_scene "${SCENE}")/ws}"

SIRIX_WS_IMPL="${TMP_DIR}/node_modules/ws/index.js" \
  node "${SCRIPT_DIR}/e2e-smoke.mjs"
