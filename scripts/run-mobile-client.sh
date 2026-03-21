#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENT_DIR=$(cd "${SCRIPT_DIR}/../client" && pwd)

USE_MOCK=${FREELOOM_USE_MOCK:-false}
SERVER_HOST=${FREELOOM_SERVER_HOST:-192.168.0.36}
API_BASE_URL=${FREELOOM_API_BASE_URL:-http://${SERVER_HOST}:8080}

cd "${CLIENT_DIR}"
flutter pub get
flutter run \
  -t apps/mobile_app/lib/main.dart \
  --dart-define=FREELOOM_USE_MOCK=${USE_MOCK} \
  --dart-define=FREELOOM_SERVER_HOST=${SERVER_HOST} \
  --dart-define=FREELOOM_API_BASE_URL=${API_BASE_URL} \
  "$@"
