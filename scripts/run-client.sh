#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENT_DIR=$(cd "${SCRIPT_DIR}/../client" && pwd)

UPDATE_DEPS=false
LIST_ONLY=false
PASSTHROUGH_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./scripts/run-client.sh [--update-deps] [--list] [-- flutter run args...]

Interactive launcher for Flutter mobile and desktop apps.

Options:
  -u, --update-deps, --pub-get   Run `flutter pub get` before launch.
      --list                     Show current launch options and exit.
  -h, --help                     Show this help message.

Examples:
  ./scripts/run-client.sh
  ./scripts/run-client.sh --update-deps
  ./scripts/run-client.sh -- --verbose
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--update-deps|--pub-get)
      UPDATE_DEPS=true
      shift
      ;;
    --list)
      LIST_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      PASSTHROUGH_ARGS+=("$@")
      break
      ;;
    *)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for parsing \`flutter devices --machine\` output." >&2
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter command not found in PATH." >&2
  exit 1
fi

if ! DEVICES_JSON=$(cd "${CLIENT_DIR}" && flutter devices --machine 2>/tmp/freeloom_flutter_devices.err); then
  echo "Failed to query Flutter devices. Run \`cd client && flutter devices\` manually to inspect the environment." >&2
  if [[ -s /tmp/freeloom_flutter_devices.err ]]; then
    cat /tmp/freeloom_flutter_devices.err >&2
  fi
  exit 1
fi

OPTIONS=()
while IFS= read -r line; do
  OPTIONS+=("${line}")
done < <(
  python3 - "${DEVICES_JSON}" <<'PY'
import json
import sys

raw = sys.argv[1]
devices = json.loads(raw)

def classify(target_platform: str):
    target = (target_platform or "").lower()
    if target.startswith("android") or target.startswith("ios"):
        return "mobile"
    if (
        target.startswith("darwin")
        or target.startswith("macos")
        or target.startswith("linux")
        or target.startswith("windows")
    ):
        return "desktop"
    return None

for device in devices:
    if not device.get("isSupported", False):
        continue

    kind = classify(device.get("targetPlatform", ""))
    if kind is None:
        continue

    if kind == "mobile":
        runner = "run-mobile-client.sh"
        app_label = "Mobile"
    else:
        runner = "run-desktop-client.sh"
        app_label = "Desktop"

    device_id = device.get("id", "")
    name = device.get("name", device_id)
    target_platform = device.get("targetPlatform", "unknown")
    emulator = "emulator" if device.get("emulator", False) else "device"

    fields = [
        app_label,
        name,
        target_platform,
        emulator,
        runner,
        device_id,
    ]
    print("\t".join(fields))
PY
)

if [[ ${#OPTIONS[@]} -eq 0 ]]; then
  cat <<'EOF' >&2
No launchable Flutter devices found for the mobile or desktop app.
Run `cd client && flutter devices` first, and ensure an emulator/simulator/device is available.
EOF
  exit 1
fi

echo "Current launch options:"
for index in "${!OPTIONS[@]}"; do
  IFS=$'\t' read -r app_label name target_platform emulator runner device_id <<<"${OPTIONS[$index]}"
  printf '  %d) [%s] %s (%s, %s)\n' \
    "$((index + 1))" \
    "${app_label}" \
    "${name}" \
    "${target_platform}" \
    "${emulator}"
done

if [[ "${LIST_ONLY}" == true ]]; then
  exit 0
fi

echo
read -r -p "Select a platform to launch [1-${#OPTIONS[@]}]: " SELECTION

if [[ ! "${SELECTION}" =~ ^[0-9]+$ ]]; then
  echo "Invalid selection: ${SELECTION}" >&2
  exit 1
fi

OPTION_INDEX=$((SELECTION - 1))
if (( OPTION_INDEX < 0 || OPTION_INDEX >= ${#OPTIONS[@]} )); then
  echo "Selection out of range: ${SELECTION}" >&2
  exit 1
fi

IFS=$'\t' read -r APP_LABEL DEVICE_NAME TARGET_PLATFORM EMULATOR RUNNER DEVICE_ID <<<"${OPTIONS[$OPTION_INDEX]}"

echo
echo "Launching ${APP_LABEL} on ${DEVICE_NAME} (${TARGET_PLATFORM})..."

RUNNER_ARGS=()
if [[ "${UPDATE_DEPS}" == true ]]; then
  RUNNER_ARGS+=(--update-deps)
fi
RUNNER_ARGS+=(-d "${DEVICE_ID}")
if (( ${#PASSTHROUGH_ARGS[@]} > 0 )); then
  RUNNER_ARGS+=("${PASSTHROUGH_ARGS[@]}")
fi

exec "${SCRIPT_DIR}/${RUNNER}" "${RUNNER_ARGS[@]}"
