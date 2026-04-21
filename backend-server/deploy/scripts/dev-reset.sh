#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

exec "${SCRIPT_DIR}/dev-restart.sh" --reset-data "$@"
