#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${SCRIPT_DIR}/../backend-server/deploy"
if [[ $# -gt 0 ]]; then
  docker compose logs -f "$1"
else
  docker compose logs -f
fi
