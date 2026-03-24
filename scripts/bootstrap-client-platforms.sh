#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

MOBILE_DIR="${ROOT_DIR}/client/apps/mobile_app"
DESKTOP_DIR="${ROOT_DIR}/client/apps/desktop_app"

if [[ ! -d "${MOBILE_DIR}" || ! -d "${DESKTOP_DIR}" ]]; then
  echo "client/apps 目录不存在，无法生成平台壳工程" >&2
  exit 1
fi

if [[ ! -d "${MOBILE_DIR}/android" || ! -d "${MOBILE_DIR}/ios" ]]; then
  echo "[bootstrap] generating mobile platforms (android, ios)"
  (
    cd "${MOBILE_DIR}"
    flutter create . --platforms=android,ios --project-name mobile_app
  )
else
  echo "[bootstrap] mobile platforms already exist"
fi

if [[ ! -d "${DESKTOP_DIR}/linux" || ! -d "${DESKTOP_DIR}/macos" || ! -d "${DESKTOP_DIR}/windows" ]]; then
  echo "[bootstrap] generating desktop platforms (linux, macos, windows)"
  (
    cd "${DESKTOP_DIR}"
    flutter create . --platforms=linux,macos,windows --project-name desktop_app
  )
else
  echo "[bootstrap] desktop platforms already exist"
fi

echo "[bootstrap] done"
