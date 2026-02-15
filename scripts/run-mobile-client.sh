#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENT_DIR=$(cd "${SCRIPT_DIR}/../client" && pwd)

USE_MOCK=${FREELOOM_USE_MOCK:-false}
API_BASE_URL=${FREELOOM_API_BASE_URL:-http://127.0.0.1:8080}

cd "${CLIENT_DIR}"
flutter pub get
flutter run \
  -t apps/mobile_app/lib/main.dart \
  --dart-define=FREELOOM_USE_MOCK=${USE_MOCK} \
  --dart-define=FREELOOM_API_BASE_URL=${API_BASE_URL} \
  "$@"
