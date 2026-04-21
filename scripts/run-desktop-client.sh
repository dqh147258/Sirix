#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENT_DIR=$(cd "${SCRIPT_DIR}/../client" && pwd)
source "${SCRIPT_DIR}/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)
USE_MOCK=${SIRIX_USE_MOCK:-false}
SERVER_HOST=${SIRIX_SERVER_HOST:-127.0.0.1}
API_BASE_URL=${SIRIX_API_BASE_URL:-http://${SERVER_HOST}:$(sirix_backend_port_for_scene "${SCENE}")}
DESKTOP_HOST=${SIRIX_DESKTOP_SERVER_HOST:-127.0.0.1}
DESKTOP_PORT_START=${SIRIX_DESKTOP_SERVER_PORT_START:-$(sirix_desktop_port_start_for_scene "${SCENE}")}
DESKTOP_PORT_END=${SIRIX_DESKTOP_SERVER_PORT_END:-$(sirix_desktop_port_end_for_scene "${SCENE}")}
UPDATE_DEPS=false
CLEAR_LOGS=false
PASSTHROUGH_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./scripts/run-desktop-client.sh [--release] [--update-deps] [-- flutter run args...]

Options:
  --release                    Use the Release Sirix scene.
  -u, --update-deps, --pub-get Run `flutter pub get` before start.
  --clear-logs                 Clear backend runtime logs for the selected scene before start.
  -h, --help                   Show this help message.

Notes:
  - Script-level `--release` only switches the Sirix scene.
  - Flutter build flags such as `--release` or `--profile` must appear after `--`.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      SCENE=release
      API_BASE_URL=${SIRIX_API_BASE_URL:-http://${SERVER_HOST}:$(sirix_backend_port_for_scene "${SCENE}")}
      DESKTOP_PORT_START=${SIRIX_DESKTOP_SERVER_PORT_START:-$(sirix_desktop_port_start_for_scene "${SCENE}")}
      DESKTOP_PORT_END=${SIRIX_DESKTOP_SERVER_PORT_END:-$(sirix_desktop_port_end_for_scene "${SCENE}")}
      shift
      ;;
    -u|--update-deps|--pub-get)
      UPDATE_DEPS=true
      shift
      ;;
    --clear-logs)
      CLEAR_LOGS=true
      shift
      ;;
    --)
      shift
      PASSTHROUGH_ARGS=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unexpected argument before '--': $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

sirix_export_scene_env "${SCENE}"
if [[ "${CLEAR_LOGS}" == true ]]; then
  sirix_clear_runtime_logs_for_scene "${SCRIPT_DIR}/../backend-server/deploy" "${SCENE}"
fi

HAS_DEVICE_FLAG=false
for arg in "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"; do
  if [[ "${arg}" == "-d" || "${arg}" == "--device-id" || "${arg}" == "--device" ]]; then
    HAS_DEVICE_FLAG=true
    break
  fi
done

if [[ "${HAS_DEVICE_FLAG}" == false ]]; then
  case "$(uname -s)" in
    Darwin)
      PASSTHROUGH_ARGS=(-d macos "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}")
      ;;
    Linux)
      PASSTHROUGH_ARGS=(-d linux "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}")
      ;;
  esac
fi

cd "${CLIENT_DIR}"
if [[ "${UPDATE_DEPS}" == true ]]; then
  flutter pub get
fi

CMD=(
  flutter
  run
  -t
  apps/desktop_app/lib/main.dart
  --dart-define=SIRIX_SCENE=${SCENE}
  --dart-define=SIRIX_USE_MOCK=${USE_MOCK}
  --dart-define=SIRIX_SERVER_HOST=${SERVER_HOST}
  --dart-define=SIRIX_API_BASE_URL=${API_BASE_URL}
  --dart-define=SIRIX_DESKTOP_SERVER_HOST=${DESKTOP_HOST}
  --dart-define=SIRIX_DESKTOP_SERVER_PORT_START=${DESKTOP_PORT_START}
  --dart-define=SIRIX_DESKTOP_SERVER_PORT_END=${DESKTOP_PORT_END}
)

if (( ${#PASSTHROUGH_ARGS[@]} > 0 )); then
  CMD+=("${PASSTHROUGH_ARGS[@]}")
fi

exec "${CMD[@]}"
