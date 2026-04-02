#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENT_DIR=$(cd "${SCRIPT_DIR}/../client" && pwd)

USE_MOCK=${FREELOOM_USE_MOCK:-false}
SERVER_HOST=${FREELOOM_SERVER_HOST:-192.168.0.36}
API_BASE_URL=${FREELOOM_API_BASE_URL:-http://${SERVER_HOST}:8080}
DESKTOP_HOST=${FREELOOM_DESKTOP_SERVER_HOST:-127.0.0.1}
DESKTOP_PORT_START=${FREELOOM_DESKTOP_SERVER_PORT_START:-9700}
DESKTOP_PORT_END=${FREELOOM_DESKTOP_SERVER_PORT_END:-9710}
UPDATE_DEPS=false
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--update-deps|--pub-get)
      UPDATE_DEPS=true
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/run-desktop-client.sh [--update-deps] [flutter run args...]

Options:
  -u, --update-deps, --pub-get   Run `flutter pub get` before start.
  -h, --help                     Show this help message.
EOF
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

HAS_DEVICE_FLAG=false
for arg in "${ARGS[@]+"${ARGS[@]}"}"; do
  if [[ "${arg}" == "-d" || "${arg}" == "--device-id" || "${arg}" == "--device" ]]; then
    HAS_DEVICE_FLAG=true
    break
  fi
done

if [[ "${HAS_DEVICE_FLAG}" == false ]]; then
  case "$(uname -s)" in
    Darwin)
      ARGS=(-d macos "${ARGS[@]+"${ARGS[@]}"}")
      ;;
    Linux)
      ARGS=(-d linux "${ARGS[@]+"${ARGS[@]}"}")
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
  --dart-define=FREELOOM_USE_MOCK=${USE_MOCK}
  --dart-define=FREELOOM_SERVER_HOST=${SERVER_HOST}
  --dart-define=FREELOOM_API_BASE_URL=${API_BASE_URL}
  --dart-define=FREELOOM_DESKTOP_SERVER_HOST=${DESKTOP_HOST}
  --dart-define=FREELOOM_DESKTOP_SERVER_PORT_START=${DESKTOP_PORT_START}
  --dart-define=FREELOOM_DESKTOP_SERVER_PORT_END=${DESKTOP_PORT_END}
)

if (( ${#ARGS[@]} > 0 )); then
  CMD+=("${ARGS[@]}")
fi

exec "${CMD[@]}"
