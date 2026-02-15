#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
SERVICE=${1:-}

cd "${DEPLOY_DIR}"
if [[ -n "${SERVICE}" ]]; then
  docker compose logs -f "${SERVICE}"
else
  docker compose logs -f
fi
