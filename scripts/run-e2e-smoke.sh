#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=${FREELOOM_E2E_TMP_DIR:-/tmp/freeloom-e2e}
CACHE_DIR=${FREELOOM_E2E_NPM_CACHE:-/tmp/npm-cache}

mkdir -p "${TMP_DIR}" "${CACHE_DIR}"
npm_config_cache="${CACHE_DIR}" npm install --prefix "${TMP_DIR}" ws >/dev/null

FREELOOM_WS_IMPL="${TMP_DIR}/node_modules/ws/index.js" \
  node "${SCRIPT_DIR}/e2e-smoke.mjs"
