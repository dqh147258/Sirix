#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PROFILE="${1:-debug}"

if [[ "${BUILD_PROFILE}" != "debug" && "${BUILD_PROFILE}" != "release" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 1
fi

if [[ "${BUILD_PROFILE}" == "release" ]]; then
  CARGO_PROFILE_FLAG="--release"
  OUT_DIR_NAME="release"
else
  CARGO_PROFILE_FLAG=""
  OUT_DIR_NAME="debug"
fi

echo "[sirix-build] building sirix-runtime (${BUILD_PROFILE})"
(
  cd "${ROOT_DIR}/third_party/codex-rs"
  export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
  cargo build ${CARGO_PROFILE_FLAG} -p sirix-runtime
)

echo "[sirix-build] building desktop-server, sirix and sirix-terminal (${BUILD_PROFILE})"
(
  cd "${ROOT_DIR}/desktop-server"
  cargo build ${CARGO_PROFILE_FLAG}
)

BIN_DIR="${HOME}/.sirix/bin"
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

ln -sfn "${SIRIX_BIN}" "${BIN_DIR}/sirix"
ln -sfn "${SIRIX_TERMINAL_BIN}" "${BIN_DIR}/sirix-terminal"
ln -sfn "${DESKTOP_SERVER_BIN}" "${BIN_DIR}/desktop-server"
ln -sfn "${SIRIX_RUNTIME_BIN}" "${BIN_DIR}/sirix-runtime"

echo "[sirix-build] installed shims:"
ls -l "${BIN_DIR}/sirix" "${BIN_DIR}/sirix-terminal" "${BIN_DIR}/desktop-server" "${BIN_DIR}/sirix-runtime"
