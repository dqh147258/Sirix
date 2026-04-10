#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
DESKTOP_SERVER_DIR="${REPO_DIR}/desktop-server"

MODE=debug
RUN_IN_BACKGROUND=false
ARGS=()

usage() {
  cat <<'EOF'
Usage: ./scripts/run-desktop-server.sh [--release] [--background] [desktop-server args...]

Builds `desktop-server` and `sirix`, installs ~/.sirix/bin shims, and starts desktop-server.

Options:
  --release      Build release binaries.
  --background   Start desktop-server in the background and write logs to ~/.sirix/runtime/logs/.
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      MODE=release
      shift
      ;;
    --background)
      RUN_IN_BACKGROUND=true
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

cd "${DESKTOP_SERVER_DIR}"

BUILD_ARGS=()
TARGET_DIR="target/debug"
if [[ "${MODE}" == "release" ]]; then
  BUILD_ARGS+=(--release)
  TARGET_DIR="target/release"
fi

echo "[sirix] building desktop-server and sirix (${MODE})..."
if (( ${#BUILD_ARGS[@]} > 0 )); then
  cargo build "${BUILD_ARGS[@]}" --bin desktop-server --bin sirix
else
  cargo build --bin desktop-server --bin sirix
fi

SIRIX_HOME="${SIRIX_HOME:-${HOME}/.sirix}"
BIN_DIR="${SIRIX_HOME}/bin"
mkdir -p "${BIN_DIR}"

DESKTOP_SERVER_BIN="${DESKTOP_SERVER_DIR}/${TARGET_DIR}/desktop-server"
SIRIX_BIN="${DESKTOP_SERVER_DIR}/${TARGET_DIR}/sirix"

ln -sf "${DESKTOP_SERVER_BIN}" "${BIN_DIR}/desktop-server"
ln -sf "${SIRIX_BIN}" "${BIN_DIR}/sirix"

if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  cat <<EOF
[sirix] ~/.sirix/bin has been prepared, but is not currently on your PATH.
Add this to your shell profile if you want `sirix` to work in normal terminals:
  export PATH="\$HOME/.sirix/bin:\$PATH"
EOF
fi

if [[ "${RUN_IN_BACKGROUND}" == true ]]; then
  LOG_DIR="${SIRIX_HOME}/runtime/logs"
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/desktop-server.log"
  echo "[sirix] starting desktop-server in background..."
  if (( ${#ARGS[@]} > 0 )); then
    nohup "${DESKTOP_SERVER_BIN}" "${ARGS[@]}" >>"${LOG_FILE}" 2>&1 &
  else
    nohup "${DESKTOP_SERVER_BIN}" >>"${LOG_FILE}" 2>&1 &
  fi
  echo "[sirix] desktop-server started. log=${LOG_FILE}"
  exit 0
fi

echo "[sirix] starting desktop-server..."
if (( ${#ARGS[@]} > 0 )); then
  exec "${DESKTOP_SERVER_BIN}" "${ARGS[@]}"
else
  exec "${DESKTOP_SERVER_BIN}"
fi
