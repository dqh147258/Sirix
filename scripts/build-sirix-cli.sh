#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)

usage() {
  cat <<'EOF'
Usage: ./scripts/build-sirix-cli.sh [--release] [debug|release]

Options:
  --release      Use the Release Sirix scene and release Rust profile.

Notes:
  - Positional `debug|release` is preserved for backward compatibility.
  - Script-level `--release` changes the Sirix scene/profile only.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      SCENE=release
      shift
      ;;
    debug|release)
      SCENE="$1"
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
done

sirix_export_scene_env "${SCENE}"

if [[ "${SCENE}" == "release" ]]; then
  CARGO_PROFILE_FLAG=(--release)
  OUT_DIR_NAME="release"
else
  CARGO_PROFILE_FLAG=()
  OUT_DIR_NAME="debug"
fi

echo "[sirix-build] building sirix-runtime (${SCENE})"
(
  cd "${ROOT_DIR}/third_party/codex-rs"
  export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
  cargo build "${CARGO_PROFILE_FLAG[@]}" -p sirix-runtime
)

echo "[sirix-build] building desktop-server, sirix and sirix-terminal (${SCENE})"
(
  cd "${ROOT_DIR}/desktop-server"
  cargo build "${CARGO_PROFILE_FLAG[@]}"
)

BIN_DIR="${SIRIX_HOME}/bin"
mkdir -p "${BIN_DIR}"

SIRIX_BIN="${ROOT_DIR}/desktop-server/target/${OUT_DIR_NAME}/sirix"
SIRIX_TERMINAL_BIN="${ROOT_DIR}/desktop-server/target/${OUT_DIR_NAME}/sirix-terminal"
DESKTOP_SERVER_BIN="${ROOT_DIR}/desktop-server/target/${OUT_DIR_NAME}/desktop-server"
SIRIX_RUNTIME_BIN="${ROOT_DIR}/third_party/codex-rs/target/${OUT_DIR_NAME}/sirix-runtime"

for required in "${SIRIX_BIN}" "${SIRIX_TERMINAL_BIN}" "${DESKTOP_SERVER_BIN}" "${SIRIX_RUNTIME_BIN}"; do
  if [[ ! -x "${required}" ]]; then
    echo "[sirix-build] missing expected binary: ${required}" >&2
    exit 1
  fi
done

sirix_install_exec_shim "${SIRIX_BIN}" "${BIN_DIR}/sirix" "${SCENE}" "${SIRIX_HOME}"
sirix_install_exec_shim "${SIRIX_TERMINAL_BIN}" "${BIN_DIR}/sirix-terminal" "${SCENE}" "${SIRIX_HOME}"
sirix_install_exec_shim "${DESKTOP_SERVER_BIN}" "${BIN_DIR}/desktop-server" "${SCENE}" "${SIRIX_HOME}"
sirix_install_exec_shim "${SIRIX_RUNTIME_BIN}" "${BIN_DIR}/sirix-runtime" "${SCENE}" "${SIRIX_HOME}"

echo "[sirix-build] installed scene-aware shims:"
ls -l "${BIN_DIR}/sirix" "${BIN_DIR}/sirix-terminal" "${BIN_DIR}/desktop-server" "${BIN_DIR}/sirix-runtime"
