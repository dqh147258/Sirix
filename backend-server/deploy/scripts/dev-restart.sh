#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

usage() {
  cat <<'EOF'
Usage: ./backend-server/deploy/scripts/dev-restart.sh [--reset-data]

Options:
  --reset-data   Restart and recreate compose volumes. This deletes local dev data.
EOF
}

RESET_DATA=false

case "${1:-}" in
  "")
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

if (($# > 0)); then
  usage >&2
  exit 1
fi

cd "${DEPLOY_DIR}"

if [[ "${RESET_DATA}" == true ]]; then
  docker compose down -v
else
  docker compose down
fi

docker compose up -d --build
docker compose ps

backend_container_id="$(docker compose ps -aq backend-server)"
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
  backend_logs="$(docker compose logs --no-color --tail=100 backend-server || true)"
  if [[ -n "${backend_logs}" ]]; then
    printf '%s\n' "${backend_logs}" >&2
  fi
  if grep -q 'role "sirix" does not exist\|password authentication failed for user "sirix"' <<<"${backend_logs}"; then
    cat >&2 <<'EOF'
Detected a Postgres role mismatch. The existing postgres volume was likely initialized before the rename to "sirix".
If you do not need the current local database contents, rerun with:
  ./backend-server/deploy/scripts/dev-restart.sh --reset-data
or:
  ./backend-server/deploy/scripts/dev-reset.sh
EOF
  fi
  exit 1
fi
