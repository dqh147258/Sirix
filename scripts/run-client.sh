#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENT_DIR=$(cd "${SCRIPT_DIR}/../client" && pwd)
source "${SCRIPT_DIR}/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)
UPDATE_DEPS=false
LIST_ONLY=false
CLEAR_LOGS=false
PASSTHROUGH_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./scripts/run-client.sh [--release] [--update-deps] [--list] [-- flutter run args...]

Interactive launcher for Flutter mobile and desktop apps.

Options:
  --release                    Use the Release Sirix scene.
  -u, --update-deps, --pub-get Run `flutter pub get` before launch.
      --clear-logs             Clear backend runtime logs for the selected scene before launch.
      --list                   Show current launch options and exit.
  -h, --help                   Show this help message.

Examples:
  ./scripts/run-client.sh
  ./scripts/run-client.sh --release
  ./scripts/run-client.sh --update-deps
  ./scripts/run-client.sh --release -- --profile
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      SCENE=release
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
    --list)
      LIST_ONLY=true
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

if ! DEVICES_JSON=$(cd "${CLIENT_DIR}" && flutter devices --machine 2>/tmp/sirix_flutter_devices.err); then
  echo "failed to query flutter devices" >&2
  if [[ -s /tmp/sirix_flutter_devices.err ]]; then
    cat /tmp/sirix_flutter_devices.err >&2
  fi
  exit 1
fi

DEVICE_ROWS=$(python3 - <<'PY' "${DEVICES_JSON}"
import json, sys
devices = json.loads(sys.argv[1])
for device in devices:
    platform = (device.get("targetPlatform") or "").lower()
    name = device.get("name") or device.get("id") or "unknown"
    device_id = device.get("id") or ""
    if not device_id:
        continue
    if any(token in platform for token in ("macos", "linux", "windows")):
        runner = "desktop"
    else:
        runner = "mobile"
    print(f"{device_id}\t{name}\t{platform}\t{runner}")
PY
)

if [[ -z "${DEVICE_ROWS}" ]]; then
  echo "no Flutter devices found" >&2
  exit 1
fi

if [[ "${LIST_ONLY}" == true ]]; then
  echo "Sirix scene: ${SCENE}"
  echo "${DEVICE_ROWS}" | awk -F '\t' '{printf "[%d] %s (%s) -> %s\n", NR, $2, $3, $4}'
  exit 0
fi

mapfile -t DEVICES <<<"${DEVICE_ROWS}"
SELECTED_INDEX=0
if (( ${#DEVICES[@]} > 1 )); then
  echo "Sirix scene: ${SCENE}"
  for idx in "${!DEVICES[@]}"; do
    IFS=$'\t' read -r device_id name platform runner <<<"${DEVICES[$idx]}"
    printf "[%d] %s (%s) -> %s\n" "$((idx + 1))" "${name}" "${platform}" "${runner}"
  done
  read -r -p "Choose a device [1-${#DEVICES[@]}]: " selection
  if [[ ! "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#DEVICES[@]} )); then
    echo "invalid device selection" >&2
    exit 1
  fi
  SELECTED_INDEX=$((selection - 1))
fi

IFS=$'\t' read -r DEVICE_ID DEVICE_NAME DEVICE_PLATFORM RUNNER_KIND <<<"${DEVICES[$SELECTED_INDEX]}"

RUNNER_SCRIPT="${SCRIPT_DIR}/run-mobile-client.sh"
if [[ "${RUNNER_KIND}" == "desktop" ]]; then
  RUNNER_SCRIPT="${SCRIPT_DIR}/run-desktop-client.sh"
fi

RUNNER_ARGS=()
if [[ "${SCENE}" == "release" ]]; then
  RUNNER_ARGS+=(--release)
fi
if [[ "${UPDATE_DEPS}" == true ]]; then
  RUNNER_ARGS+=(--update-deps)
fi
if [[ "${CLEAR_LOGS}" == true ]]; then
  RUNNER_ARGS+=(--clear-logs)
fi

HAS_PASSTHROUGH_DEVICE_FLAG=false
for arg in "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"; do
  if [[ "${arg}" == "-d" || "${arg}" == "--device-id" || "${arg}" == "--device" ]]; then
    HAS_PASSTHROUGH_DEVICE_FLAG=true
    break
  fi
done

RUNNER_ARGS+=(--)
if [[ "${HAS_PASSTHROUGH_DEVICE_FLAG}" == false ]]; then
  # 仅当用户没有在 `--` 之后显式传入 Flutter 的设备参数时，才注入交互式选择结果，
  # 这样既保留现有交互体验，也避免把两个 `-d/--device-id` 一起传给 flutter run。
  RUNNER_ARGS+=(-d "${DEVICE_ID}")
fi
if (( ${#PASSTHROUGH_ARGS[@]} > 0 )); then
  RUNNER_ARGS+=("${PASSTHROUGH_ARGS[@]}")
fi

exec "${RUNNER_SCRIPT}" "${RUNNER_ARGS[@]}"
