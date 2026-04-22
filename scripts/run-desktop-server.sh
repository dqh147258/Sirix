#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
DESKTOP_SERVER_DIR="${REPO_DIR}/desktop-server"
source "${SCRIPT_DIR}/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)
RUN_IN_BACKGROUND=false
CLEAR_LOGS=false
ARGS=()

usage() {
  cat <<'EOF'
Usage: ./scripts/run-desktop-server.sh [--release] [--background] [desktop-server args...]

Builds the scene-matched `desktop-server`, `sirix`, `sirix-terminal`, and
`sirix-runtime`, installs scene-aware shims, and starts desktop-server.

Options:
  --release      Use the Release Sirix scene and release Rust profile.
  --background   Start desktop-server in the background and write logs to the
                 scene-specific runtime log directory.
  --clear-logs   Clear backend runtime logs for the selected scene before start.
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      SCENE=release
      shift
      ;;
    --background)
      RUN_IN_BACKGROUND=true
      shift
      ;;
    --clear-logs)
      CLEAR_LOGS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

sirix_export_scene_env "${SCENE}"
if [[ "${CLEAR_LOGS}" == true ]]; then
  sirix_clear_runtime_logs_for_scene "${REPO_DIR}/backend-server/deploy" "${SCENE}"
fi

BUILD_ARGS=()
TARGET_DIR="target/debug"
RUNTIME_TARGET_DIR="debug"
if [[ "${SCENE}" == "release" ]]; then
  BUILD_ARGS+=(--release)
  TARGET_DIR="target/release"
  RUNTIME_TARGET_DIR="release"
fi

echo "[sirix] building desktop-server, sirix, sirix-terminal, and sirix-runtime (${SCENE})..."
(
  cd "${REPO_DIR}/third_party/codex-rs"
  export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
  cargo build "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" -p sirix-runtime
)
(
  cd "${DESKTOP_SERVER_DIR}"
  cargo build "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" --bin desktop-server --bin sirix --bin sirix-terminal
)

BIN_DIR="${SIRIX_HOME}/bin"
mkdir -p "${BIN_DIR}"

DESKTOP_SERVER_BIN="${DESKTOP_SERVER_DIR}/${TARGET_DIR}/desktop-server"
SIRIX_BIN="${DESKTOP_SERVER_DIR}/${TARGET_DIR}/sirix"
SIRIX_TERMINAL_BIN="${DESKTOP_SERVER_DIR}/${TARGET_DIR}/sirix-terminal"
SIRIX_RUNTIME_BIN="${REPO_DIR}/third_party/codex-rs/target/${RUNTIME_TARGET_DIR}/sirix-runtime"

for required in "${DESKTOP_SERVER_BIN}" "${SIRIX_BIN}" "${SIRIX_TERMINAL_BIN}" "${SIRIX_RUNTIME_BIN}"; do
  if [[ ! -x "${required}" ]]; then
    echo "[sirix] missing expected binary: ${required}" >&2
    exit 1
  fi
done

sirix_install_exec_shim "${DESKTOP_SERVER_BIN}" "${BIN_DIR}/desktop-server" "${SCENE}" "${SIRIX_HOME}"
sirix_install_exec_shim "${SIRIX_BIN}" "${BIN_DIR}/sirix" "${SCENE}" "${SIRIX_HOME}"
sirix_install_exec_shim "${SIRIX_TERMINAL_BIN}" "${BIN_DIR}/sirix-terminal" "${SCENE}" "${SIRIX_HOME}"
sirix_install_exec_shim "${SIRIX_RUNTIME_BIN}" "${BIN_DIR}/sirix-runtime" "${SCENE}" "${SIRIX_HOME}"

if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  cat <<EOF
[sirix] ${BIN_DIR} has been prepared, but is not currently on your PATH.
Add this to your shell profile if you want scene-matched Sirix binaries to work in normal terminals:
  export PATH="${BIN_DIR}:\$PATH"
EOF
fi

if [[ "${RUN_IN_BACKGROUND}" == true ]]; then
  LOG_DIR="${SIRIX_HOME}/runtime/logs"
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/desktop-server.log"
  echo "[sirix] starting desktop-server in background for scene=${SCENE}..."
  if (( ${#ARGS[@]} > 0 )); then
    nohup env \
      SIRIX_SCENE="${SCENE}" \
      SIRIX_HOME="${SIRIX_HOME}" \
      "${DESKTOP_SERVER_BIN}" "${ARGS[@]}" >>"${LOG_FILE}" 2>&1 &
  else
    nohup env \
      SIRIX_SCENE="${SCENE}" \
      SIRIX_HOME="${SIRIX_HOME}" \
      "${DESKTOP_SERVER_BIN}" >>"${LOG_FILE}" 2>&1 &
  fi
  echo "[sirix] desktop-server started. log=${LOG_FILE}"
  exit 0
fi

echo "[sirix] starting desktop-server for scene=${SCENE}..."
if (( ${#ARGS[@]} > 0 )); then
  exec env \
    SIRIX_SCENE="${SCENE}" \
    SIRIX_HOME="${SIRIX_HOME}" \
    "${DESKTOP_SERVER_BIN}" "${ARGS[@]}"
else
  exec env \
    SIRIX_SCENE="${SCENE}" \
    SIRIX_HOME="${SIRIX_HOME}" \
    "${DESKTOP_SERVER_BIN}"
fi
