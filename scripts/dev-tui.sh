#!/usr/bin/env bash
set -euo pipefail

# Sirix 本地联调 TUI 控制台。
# 统一管理 backend / desktop-server / CLI build / desktop client / mobile client，
# 支持 scene-aware 的并行启停、状态查看、冲突检测、日志清理、批量操作，
# 并尽量保持在 macOS 自带 Bash 3.2 / Linux / Windows Git Bash 下可运行。

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
source "${SCRIPT_DIR}/lib/sirix-scene.sh"

SCENE=$(sirix_resolve_scene_from_env)

usage() {
  cat <<'USAGE'
Usage: ./scripts/dev-tui.sh [--release]

Options:
  --release      Use the Release Sirix scene.
  -h, --help     Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      SCENE=release
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

sirix_export_scene_env "${SCENE}" "${REPO_DIR}/backend-server/deploy"

MANAGER_HOME="${SIRIX_HOME}/runtime/tui-manager"
LOG_DIR="${MANAGER_HOME}/logs"
STATE_DIR="${MANAGER_HOME}/state"
FAILED_RUNS_DIR="${STATE_DIR}/failed-runs"
mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${FAILED_RUNS_DIR}"

readonly MANAGER_HOME LOG_DIR STATE_DIR
readonly HISTORY_FILE="${STATE_DIR}/command-history.txt"
readonly FAILED_RUNS_DIR
readonly FAILURE_HISTORY_FILE="${STATE_DIR}/failure-history.tsv"
readonly BACKEND_DEPLOY_DIR="${REPO_DIR}/backend-server/deploy"
readonly CLIENT_DIR="${REPO_DIR}/client"
readonly MANAGER_LOG_FILE="${LOG_DIR}/manager.log"

LAST_NOTICE=''
LAST_NOTICE_LEVEL='INFO'
CAN_USE_COLOR=false
COLOR_RESET=''
COLOR_DIM=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_RED=''
COLOR_CYAN=''
COLOR_MAGENTA=''
READ_INPUT_ALREADY_RECORDED=false

supports_interactive_tty() {
  [[ -t 0 && -t 1 ]]
}

init_colors() {
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    local colors
    colors=$(tput colors 2>/dev/null || printf '0')
    if [[ "${colors}" =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
      CAN_USE_COLOR=true
      COLOR_RESET=$(tput sgr0)
      COLOR_DIM=$(tput dim)
      COLOR_GREEN=$(tput setaf 2)
      COLOR_YELLOW=$(tput setaf 3)
      COLOR_BLUE=$(tput setaf 4)
      COLOR_RED=$(tput setaf 1)
      COLOR_CYAN=$(tput setaf 6)
      COLOR_MAGENTA=$(tput setaf 5)
    fi
  fi
}

paint() {
  local color="$1"
  local text="$2"
  if [[ "${CAN_USE_COLOR}" == true ]]; then
    printf '%b%s%b' "${color}" "${text}" "${COLOR_RESET}"
  else
    printf '%s' "${text}"
  fi
}

style_code() {
  local code="$1"
  local kind="$2"
  case "${kind}" in
    start) paint "${COLOR_GREEN}" "${code}" ;;
    stop) paint "${COLOR_YELLOW}" "${code}" ;;
    restart) paint "${COLOR_BLUE}" "${code}" ;;
    special) paint "${COLOR_MAGENTA}" "${code}" ;;
    refresh) paint "${COLOR_CYAN}" "${code}" ;;
    quit) paint "${COLOR_RED}" "${code}" ;;
    *) printf '%s' "${code}" ;;
  esac
}

set_notice() {
  LAST_NOTICE="$1"
  LAST_NOTICE_LEVEL="$2"
}

print_notice() {
  [[ -z "${LAST_NOTICE}" ]] && return 0
  local rendered
  case "${LAST_NOTICE_LEVEL}" in
    ERROR) rendered=$(paint "${COLOR_RED}" "${LAST_NOTICE}") ;;
    WARN) rendered=$(paint "${COLOR_YELLOW}" "${LAST_NOTICE}") ;;
    INFO) rendered=$(paint "${COLOR_CYAN}" "${LAST_NOTICE}") ;;
    SUCCESS) rendered=$(paint "${COLOR_GREEN}" "${LAST_NOTICE}") ;;
    *) rendered="${LAST_NOTICE}" ;;
  esac
  printf '%s\n\n' "${rendered}"
}

log_note() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [%s] %s\n' "${timestamp}" "${level}" "${message}" | tee -a "${MANAGER_LOG_FILE}" >/dev/null
}

scene_args() {
  if [[ "${SCENE}" == 'release' ]]; then
    printf '%s\n' '--release'
  fi
}

component_label() {
  case "$1" in
    backend) printf '%s\n' 'Backend Server' ;;
    desktop_server) printf '%s\n' 'Desktop Server' ;;
    cli_build) printf '%s\n' 'CLI Build' ;;
    desktop_client) printf '%s\n' 'Desktop Client' ;;
    mobile_client) printf '%s\n' 'Mobile Client' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

component_is_task() {
  [[ "$1" == 'cli_build' ]]
}

component_pid_file() { printf '%s/%s.pid\n' "${STATE_DIR}" "$1"; }
component_child_pid_file() { printf '%s/%s.child.pid\n' "${STATE_DIR}" "$1"; }
component_wrapper_file() { printf '%s/%s.wrapper.sh\n' "${STATE_DIR}" "$1"; }
component_status_file() { printf '%s/%s.status\n' "${STATE_DIR}" "$1"; }
component_meta_file() { printf '%s/%s.meta\n' "${STATE_DIR}" "$1"; }
component_log_file() { printf '%s/%s.log\n' "${LOG_DIR}" "$1"; }

write_component_status() {
  local component="$1"
  local state="$2"
  local exit_code="$3"
  local message="$4"
  cat >"$(component_status_file "${component}")" <<STATUS
state=${state}
exit_code=${exit_code}
message=${message}
updated_at=$(date '+%Y-%m-%d %H:%M:%S')
STATUS
}

write_component_meta() {
  local component="$1"
  shift
  cat >"$(component_meta_file "${component}")" <<META
label=$(component_label "${component}")
scene=${SCENE}
log_file=$(component_log_file "${component}")
$*
META
}

read_key_from_file() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 1
  awk -F '=' -v wanted="${key}" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "${file}"
}

read_status_value() {
  read_key_from_file "$(component_status_file "$1")" "$2"
}

read_meta_value() {
  read_key_from_file "$(component_meta_file "$1")" "$2"
}

pid_is_running() {
  local pid="$1"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

cleanup_stale_component_state() {
  local component="$1"
  local wrapper_pid child_pid
  if [[ -f "$(component_pid_file "${component}")" ]]; then
    wrapper_pid=$(<"$(component_pid_file "${component}")")
    if ! pid_is_running "${wrapper_pid}"; then
      rm -f "$(component_pid_file "${component}")"
    fi
  fi
  if [[ -f "$(component_child_pid_file "${component}")" ]]; then
    child_pid=$(<"$(component_child_pid_file "${component}")")
    if ! pid_is_running "${child_pid}"; then
      rm -f "$(component_child_pid_file "${component}")"
    fi
  fi
}

component_is_running() {
  local component="$1"
  cleanup_stale_component_state "${component}"
  if [[ -f "$(component_pid_file "${component}")" ]] && pid_is_running "$(<"$(component_pid_file "${component}")")"; then
    return 0
  fi
  if [[ -f "$(component_child_pid_file "${component}")" ]] && pid_is_running "$(<"$(component_child_pid_file "${component}")")"; then
    return 0
  fi
  return 1
}

status_text_with_color() {
  local state="$1"
  local exit_code="$2"
  local message="$3"
  local text
  case "${state}" in
    running)
      text='运行中'
      [[ -n "${message}" ]] && text+=" | ${message}"
      paint "${COLOR_GREEN}" "${text}"
      ;;
    launching)
      text='启动中'
      [[ -n "${message}" ]] && text+=" | ${message}"
      paint "${COLOR_BLUE}" "${text}"
      ;;
    completed)
      text='已完成'
      [[ -n "${message}" ]] && text+=" | ${message}"
      paint "${COLOR_CYAN}" "${text}"
      ;;
    failed)
      text='失败'
      [[ -n "${message}" ]] && text+=" | ${message}"
      [[ -n "${exit_code}" ]] && text+=" | exit=${exit_code}"
      paint "${COLOR_RED}" "${text}"
      ;;
    stopped)
      text='已停止'
      [[ -n "${message}" ]] && text+=" | ${message}"
      [[ -n "${exit_code}" && "${exit_code}" != '0' ]] && text+=" | exit=${exit_code}"
      paint "${COLOR_YELLOW}" "${text}"
      ;;
    *)
      paint "${COLOR_DIM}" '未启动'
      ;;
  esac
}

backend_container_id() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  (cd "${BACKEND_DEPLOY_DIR}" && docker compose \
    --env-file "$(sirix_compose_env_file_for_scene "${BACKEND_DEPLOY_DIR}" "${SCENE}")" \
    -f docker-compose.yml \
    ps -aq backend-server 2>/dev/null) || true
}

backend_is_running() {
  local container_id state
  container_id=$(backend_container_id)
  [[ -n "${container_id}" ]] || return 1
  state=$(docker inspect -f '{{.State.Status}}' "${container_id}" 2>/dev/null || true)
  [[ "${state}" == 'running' ]]
}

backend_status_summary() {
  if ! command -v docker >/dev/null 2>&1; then
    paint "${COLOR_RED}" '未检测到 docker'
    return
  fi
  if backend_is_running; then
    local container_id
    container_id=$(backend_container_id)
    paint "${COLOR_GREEN}" "运行中 (container=${container_id:0:12})"
    return
  fi

  local state exit_code message
  state=$(read_status_value backend state 2>/dev/null || true)
  exit_code=$(read_status_value backend exit_code 2>/dev/null || true)
  message=$(read_status_value backend message 2>/dev/null || true)
  if [[ -n "${state}" ]]; then
    status_text_with_color "${state}" "${exit_code}" "${message}"
    return
  fi
  paint "${COLOR_DIM}" '未启动'
}

component_status_summary() {
  local component="$1"
  if [[ "${component}" == 'backend' ]]; then
    backend_status_summary
    return
  fi
  if component_is_running "${component}"; then
    local wrapper_pid
    wrapper_pid='-'
    if [[ -f "$(component_pid_file "${component}")" ]]; then
      wrapper_pid=$(<"$(component_pid_file "${component}")")
    fi
    status_text_with_color running '' "pid=${wrapper_pid}"
    return
  fi
  local state exit_code message
  state=$(read_status_value "${component}" state 2>/dev/null || true)
  exit_code=$(read_status_value "${component}" exit_code 2>/dev/null || true)
  message=$(read_status_value "${component}" message 2>/dev/null || true)
  if [[ -n "${state}" ]]; then
    status_text_with_color "${state}" "${exit_code}" "${message}"
    return
  fi
  paint "${COLOR_DIM}" '未启动'
}

format_code_group() {
  local start_code="$1" stop_code="$2" restart_code="$3"
  printf '%s/%s/%s' \
    "$(style_code "${start_code}" start)" \
    "$(style_code "${stop_code}" stop)" \
    "$(style_code "${restart_code}" restart)"
}

print_status_table() {
  printf 'Scene: %s\n' "${SCENE}"
  printf 'Home : %s\n' "${SIRIX_HOME}"
  printf 'Logs : %s\n' "${LOG_DIR}"
  printf '\n'
  printf '%-9s %-18s %s\n' 'Code' 'Component' 'Status'
  printf '%-9s %-18s %s\n' '---------' '------------------' '---------------------------------------------'
  printf '%-9s %-18s %s\n' "$(format_code_group 1 6 B)" 'Backend Server' "$(component_status_summary backend)"
  printf '%-9s %-18s %s\n' "$(format_code_group 2 7 C)" 'Desktop Server' "$(component_status_summary desktop_server)"
  printf '%-9s %-18s %s\n' "$(format_code_group 3 A D)" 'CLI Build' "$(component_status_summary cli_build)"
  printf '%-9s %-18s %s\n' "$(format_code_group 4 8 E)" 'Desktop Client' "$(component_status_summary desktop_client)"
  printf '%-9s %-18s %s\n' "$(format_code_group 5 9 F)" 'Mobile Client' "$(component_status_summary mobile_client)"
  printf '\n'
}

print_menu() {
  printf '%s  Start Backend Server      %s  Stop Backend Server       %s  Restart Backend Server\n' \
    "$(style_code 1 start)" "$(style_code 6 stop)" "$(style_code B restart)"
  printf '%s  Start Desktop Server      %s  Stop Desktop Server       %s  Restart Desktop Server\n' \
    "$(style_code 2 start)" "$(style_code 7 stop)" "$(style_code C restart)"
  printf '%s  Build CLI                 %s  Stop CLI Build            %s  Restart CLI Build\n' \
    "$(style_code 3 start)" "$(style_code A stop)" "$(style_code D restart)"
  printf '%s  Start Desktop Client      %s  Stop Desktop Client       %s  Restart Desktop Client\n' \
    "$(style_code 4 start)" "$(style_code 8 stop)" "$(style_code E restart)"
  printf '%s  Start Mobile Client       %s  Stop Mobile Client        %s  Restart Mobile Client\n' \
    "$(style_code 5 start)" "$(style_code 9 stop)" "$(style_code F restart)"
  printf '%s  Clear Logs                %s  All Start/On              %s  All Stop/Off\n' \
    "$(style_code L special)" "$(style_code O start)" "$(style_code X stop)"
  printf '%s  All Restart               %s  Refresh Status            %s  Quit\n' \
    "$(style_code R restart)" "$(style_code S refresh)" "$(style_code Q quit)"
  printf '%s  View Failed Logs\n' "$(style_code V special)"
  printf '\n'
  printf '输入示例: 12   /   48L   /   O   /   RF\n'
  printf '支持上下方向键回看历史指令（TTY 模式下与命令行类似）。\n'
}

init_command_history() {
  touch "${HISTORY_FILE}"
  touch "${FAILURE_HISTORY_FILE}"
  if supports_interactive_tty; then
    set -o emacs
    set -o history
    HISTFILE="${HISTORY_FILE}"
    HISTSIZE=200
    HISTFILESIZE=500
    HISTCONTROL=ignoredups
    history -c
    history -r "${HISTORY_FILE}" 2>/dev/null || true
  fi
}

register_failed_task() {
  local component="$1"
  local action="$2"
  local message="$3"
  local source_log="$4"
  local timestamp snapshot_path safe_message label

  mkdir -p "${FAILED_RUNS_DIR}"
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  label=$(component_label "${component}")
  safe_message=$(printf '%s' "${message}" | tr '\t\r\n' ' ' | sed 's/[[:space:]]\+/ /g')
  snapshot_path="${FAILED_RUNS_DIR}/$(date '+%Y%m%d-%H%M%S')-${component}-${action}.log"

  if [[ -n "${source_log}" && -f "${source_log}" ]]; then
    cp "${source_log}" "${snapshot_path}" 2>/dev/null || cat "${source_log}" >"${snapshot_path}"
  else
    printf '%s\n' "${safe_message}" >"${snapshot_path}"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${timestamp}" \
    "${component}" \
    "${label}" \
    "${action}" \
    "${safe_message}" \
    "${snapshot_path}" >>"${FAILURE_HISTORY_FILE}"
}

remember_command_history() {
  local raw_input="$1"
  [[ -z "${raw_input}" ]] && return 0
  if [[ "${READ_INPUT_ALREADY_RECORDED}" == true ]]; then
    READ_INPUT_ALREADY_RECORDED=false
    _SIRIX_TUI_LAST_HISTORY_ENTRY="${raw_input}"
    return 0
  fi
  if [[ "${_SIRIX_TUI_LAST_HISTORY_ENTRY:-}" == "${raw_input}" ]]; then
    return 0
  fi
  if supports_interactive_tty; then
    history -s "${raw_input}" 2>/dev/null || true
  fi
  printf '%s\n' "${raw_input}" >>"${HISTORY_FILE}"
  _SIRIX_TUI_LAST_HISTORY_ENTRY="${raw_input}"
}

python_history_input() {
  python3 - "${HISTORY_FILE}" <<'PY'
import os
import sys

histfile = sys.argv[1]
prompt = "请选择操作: "

try:
    import readline  # noqa: F401
except Exception:
    sys.exit(10)

try:
    import readline
    if os.path.exists(histfile):
        readline.read_history_file(histfile)
except Exception:
    pass

try:
    line = input(prompt)
except EOFError:
    sys.exit(1)

line = line.rstrip("\n")

if line:
    try:
        last = None
        length = readline.get_current_history_length()
        if length:
            last = readline.get_history_item(length)
        if last != line:
            readline.add_history(line)
        readline.write_history_file(histfile)
    except Exception:
        pass

sys.stdout.write(line)
PY
}

read_command_input() {
  local input
  READ_INPUT_ALREADY_RECORDED=false
  if supports_interactive_tty; then
    if command -v python3 >/dev/null 2>&1; then
      local python_output python_status
      if python_output=$(python_history_input); then
        READ_INPUT_ALREADY_RECORDED=true
        printf '%s' "${python_output}"
        return 0
      else
        python_status=$?
        if [[ "${python_status}" -eq 1 ]]; then
          return 1
        fi
      fi
    fi
    # 回退到 bash 自带的 readline 模式；某些环境下它对方向键支持不稳定，
    # 所以优先走上面的 Python readline。
    read -e -r -p '请选择操作: ' input || return 1
  else
    read -r -p '请选择操作: ' input || return 1
  fi
  printf '%s' "${input}"
}

normalize_selection() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:],;'
}

desktop_server_probe_python() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' 'python3'
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    printf '%s\n' 'python'
    return 0
  fi
  return 1
}

probe_desktop_server_port_with_curl() {
  local host="$1"
  local port_start="$2"
  local port_end="$3"
  local port
  for ((port = port_start; port <= port_end; port++)); do
    if curl -fsS --max-time 1 "http://${host}:${port}/health" >/dev/null 2>&1; then
      printf '%s\n' "${port}"
      return 0
    fi
  done
  return 1
}

probe_desktop_server_port() {
  local python_cmd host port_start port_end
  host="${SIRIX_DESKTOP_SERVER_HOST:-127.0.0.1}"
  port_start="${SIRIX_DESKTOP_SERVER_PORT_START:-$(sirix_desktop_port_start_for_scene "${SCENE}")}"
  port_end="${SIRIX_DESKTOP_SERVER_PORT_END:-$(sirix_desktop_port_end_for_scene "${SCENE}")}"
  if (( port_end < port_start )); then
    port_end="${port_start}"
  fi

  # 先走 curl，保持探活实现轻量且无 Python 依赖；
  # 若运行环境缺少 curl，再回退到 Python 标准库 HTTP 探测。
  if command -v curl >/dev/null 2>&1; then
    probe_desktop_server_port_with_curl "${host}" "${port_start}" "${port_end}"
    return $?
  fi

  python_cmd=$(desktop_server_probe_python) || return 1

  "${python_cmd}" - "${host}" "${port_start}" "${port_end}" <<'PY'
import sys
import urllib.error
import urllib.request

host = sys.argv[1]
start = int(sys.argv[2])
end = int(sys.argv[3])
if end < start:
    end = start

for port in range(start, end + 1):
    try:
        with urllib.request.urlopen(
            f"http://{host}:{port}/health",
            timeout=0.5,
        ) as response:
            if 200 <= response.status < 300:
                print(port)
                sys.exit(0)
    except (urllib.error.URLError, TimeoutError, ValueError):
        continue

sys.exit(1)
PY
}

wait_for_desktop_server_ready() {
  local timeout_secs="${1:-180}"
  local waited=0
  local port state exit_code

  while (( waited < timeout_secs )); do
    if port=$(probe_desktop_server_port 2>/dev/null); then
      printf '%s\n' "${port}"
      return 0
    fi

    state=$(read_status_value desktop_server state 2>/dev/null || true)
    exit_code=$(read_status_value desktop_server exit_code 2>/dev/null || true)
    case "${state}" in
      failed)
        return 1
        ;;
      stopped)
        if [[ -n "${exit_code}" && "${exit_code}" != '0' ]]; then
          return 1
        fi
        ;;
    esac

    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

ensure_desktop_server_ready_for_flutter() {
  local port

  if port=$(probe_desktop_server_port 2>/dev/null); then
    write_component_status desktop_server running 0 "health ok | port=${port}"
    log_note INFO "检测到 Desktop Server 已就绪，port=${port}。"
    printf '%s\n' "${port}"
    return 0
  fi

  # 用户要求 Flutter 必须在 Desktop Server 启动并通过健康检查后再启动，
  # 所以这里把 TUI 的 Desktop Client 入口改成显式前置依赖：
  # 先确保 desktop-server 已被拉起，再等待 `/health` 真正可用，最后才允许
  # `flutter run` 继续执行，避免桌面端在本地 WS/HTTP 还没监听时抢跑。
  if component_is_running desktop_server; then
    log_note INFO 'Desktop Server 正在运行或启动中，等待健康检查通过后再启动 Flutter。'
  else
    log_note INFO 'Desktop Client 依赖 Desktop Server，先启动 Desktop Server。'
    start_desktop_server || return 1
  fi

  if port=$(wait_for_desktop_server_ready 180); then
    write_component_status desktop_server running 0 "health ok | port=${port}"
    log_note INFO "Desktop Server 健康检查通过，port=${port}。"
    printf '%s\n' "${port}"
    return 0
  fi

  write_component_status desktop_server failed 1 'desktop-server health check timed out'
  log_note ERROR 'Desktop Server 未在超时时间内通过健康检查，已阻止 Flutter 启动。'
  return 1
}

launch_managed_component() {
  local component="$1"
  shift
  local label log_file wrapper_file pid_file child_pid_file status_file failure_history_file failed_runs_dir
  label=$(component_label "${component}")
  log_file=$(component_log_file "${component}")
  wrapper_file=$(component_wrapper_file "${component}")
  pid_file=$(component_pid_file "${component}")
  child_pid_file=$(component_child_pid_file "${component}")
  status_file=$(component_status_file "${component}")
  failure_history_file="${FAILURE_HISTORY_FILE}"
  failed_runs_dir="${FAILED_RUNS_DIR}"

  if component_is_running "${component}"; then
    log_note INFO "${label} 已在运行，跳过重复启动。"
    set_notice "${label} 已在运行，跳过重复启动。" INFO
    return 0
  fi

  local command_string
  command_string=$(printf '%q ' "$@")
  write_component_status "${component}" launching '' 'launch requested'
  write_component_meta "${component}" "command=${command_string}"

  cat >"${wrapper_file}" <<EOF_WRAPPER
#!/usr/bin/env bash
set -uo pipefail
status_file=$(printf '%q' "${status_file}")
pid_file=$(printf '%q' "${pid_file}")
child_pid_file=$(printf '%q' "${child_pid_file}")
failure_history_file=$(printf '%q' "${failure_history_file}")
failed_runs_dir=$(printf '%q' "${failed_runs_dir}")
log_file=$(printf '%q' "${log_file}")
component_name=$(printf '%q' "${component}")
component_label=$(printf '%q' "${label}")

write_status() {
  local state="\$1"
  local exit_code="\$2"
  local message="\$3"
  cat >"\${status_file}" <<STATUS
state=\${state}
exit_code=\${exit_code}
message=\${message}
updated_at=\$(date '+%Y-%m-%d %H:%M:%S')
STATUS
}
cleanup() {
  rm -f "\${pid_file}" "\${child_pid_file}"
}
record_failure() {
  local exit_code="\$1"
  local message="\$2"
  local timestamp snapshot_path safe_message
  mkdir -p "\${failed_runs_dir}"
  timestamp=\$(date '+%Y-%m-%d %H:%M:%S')
  safe_message=\$(printf '%s' "\${message}" | tr '\t\r\n' ' ' | sed 's/[[:space:]]\+/ /g')
  snapshot_path="\${failed_runs_dir}/\$(date '+%Y%m%d-%H%M%S')-\${component_name}-start.log"
  if [[ -f "\${log_file}" ]]; then
    cp "\${log_file}" "\${snapshot_path}" 2>/dev/null || cat "\${log_file}" >"\${snapshot_path}"
  else
    printf '%s\n' "\${safe_message}" >"\${snapshot_path}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "\${timestamp}" \
    "\${component_name}" \
    "\${component_label}" \
    'start' \
    "\${safe_message}" \
    "\${snapshot_path}" >>"\${failure_history_file}"
}
supports_setsid=false
case "\$(uname -s)" in
  CYGWIN*|MINGW*|MSYS*) ;;
  *) command -v setsid >/dev/null 2>&1 && supports_setsid=true ;;
esac
write_status running '' 'running'
if [[ "\${supports_setsid}" == true ]]; then
  setsid ${command_string}&
else
  ${command_string}&
fi
child_pid=\$!
printf '%s\n' "\${child_pid}" >"\${child_pid_file}"
terminate_child() {
  local kill_target="\${child_pid}"
  if [[ "\${supports_setsid}" == true ]]; then
    kill_target="-\${child_pid}"
  fi
  kill -TERM -- "\${kill_target}" 2>/dev/null || kill -TERM "\${child_pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    if ! kill -0 "\${child_pid}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  kill -KILL -- "\${kill_target}" 2>/dev/null || kill -KILL "\${child_pid}" 2>/dev/null || true
}
on_term() {
  terminate_child
  wait "\${child_pid}" 2>/dev/null || true
  write_status stopped 143 'terminated by dev-tui'
  cleanup
  exit 143
}
trap on_term TERM INT
wait "\${child_pid}"
exit_code=\$?
if [[ "\${exit_code}" == '0' ]]; then
  write_status completed 0 'completed'
else
  write_status failed "\${exit_code}" "exit \${exit_code}"
  record_failure "\${exit_code}" "exit \${exit_code}, see \${log_file}"
fi
cleanup
exit "\${exit_code}"
EOF_WRAPPER
  chmod +x "${wrapper_file}"

  nohup bash "${wrapper_file}" >>"${log_file}" 2>&1 &
  printf '%s\n' "$!" >"${pid_file}"
  log_note INFO "${label} 启动命令已下发，日志: ${log_file}"
}

wait_for_component_settle() {
  local component="$1"
  local action="$2"
  local timeout_secs="$3"
  local waited=0
  while (( waited < timeout_secs )); do
    if component_is_running "${component}"; then
      return 0
    fi
    local state exit_code
    state=$(read_status_value "${component}" state 2>/dev/null || true)
    exit_code=$(read_status_value "${component}" exit_code 2>/dev/null || true)
    case "${state}" in
      completed)
        return 0
        ;;
      failed)
        return 1
        ;;
      stopped)
        if [[ -n "${exit_code}" && "${exit_code}" != '0' ]]; then
          return 1
        fi
        return 0
        ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

kill_managed_component() {
  local component="$1"
  local label wrapper_pid child_pid
  label=$(component_label "${component}")
  if ! component_is_running "${component}"; then
    write_component_status "${component}" stopped '' 'manual stop skipped: not running'
    log_note INFO "${label} 当前未运行，无需停止。"
    return 0
  fi

  wrapper_pid=''
  child_pid=''
  if [[ -f "$(component_pid_file "${component}")" ]]; then
    wrapper_pid=$(<"$(component_pid_file "${component}")")
  fi
  if [[ -f "$(component_child_pid_file "${component}")" ]]; then
    child_pid=$(<"$(component_child_pid_file "${component}")")
  fi

  [[ -n "${wrapper_pid}" ]] && kill -TERM "${wrapper_pid}" 2>/dev/null || true
  [[ -n "${child_pid}" ]] && kill -TERM "${child_pid}" 2>/dev/null || true

  local _i
  for _i in 1 2 3 4 5 6; do
    if ! component_is_running "${component}"; then
      break
    fi
    sleep 1
  done

  if component_is_running "${component}"; then
    [[ -n "${wrapper_pid}" ]] && kill -KILL "${wrapper_pid}" 2>/dev/null || true
    [[ -n "${child_pid}" ]] && kill -KILL "${child_pid}" 2>/dev/null || true
  fi

  rm -f "$(component_pid_file "${component}")" "$(component_child_pid_file "${component}")"
  write_component_status "${component}" stopped 143 'terminated by dev-tui'
  log_note INFO "${label} 已停止。"
}

mobile_device_info() {
  if ! command -v flutter >/dev/null 2>&1; then
    printf 'ERR\tflutter command not found\n'
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'ERR\tpython3 command not found\n'
    return 0
  fi

  local devices_json error_file
  error_file=$(mktemp)
  if ! devices_json=$(cd "${CLIENT_DIR}" && flutter devices --machine 2>"${error_file}"); then
    local error_message='failed to query flutter devices'
    if [[ -s "${error_file}" ]]; then
      local compact_error
      compact_error=$(tr '\n' ' ' <"${error_file}" | sed 's/[[:space:]]\+/ /g')
      printf '[flutter devices error] %s\n' "${compact_error}" >>"$(component_log_file mobile_client)"
      error_message='failed to query flutter devices; see mobile_client.log'
    fi
    rm -f "${error_file}"
    printf 'ERR\t%s\n' "${error_message}"
    return 0
  fi
  rm -f "${error_file}"

  python3 - <<'PY' "${devices_json}" "${SIRIX_TUI_MOBILE_DEVICE_ID:-}"
import json, sys

devices = json.loads(sys.argv[1])
hint = sys.argv[2].strip().lower()
mobile = []
for device in devices:
    device_id = device.get("id") or ""
    if not device_id:
        continue
    platform = (device.get("targetPlatform") or "").lower()
    if platform.startswith("android") or platform.startswith("ios"):
        mobile.append(device)

if not mobile:
    print("NONE\tno supported mobile device detected")
    sys.exit(0)

selected = None
if hint:
    for device in mobile:
        if (device.get("id") or "").lower() == hint:
            selected = device
            break
    if selected is None:
        print(f"ERR\tSIRIX_TUI_MOBILE_DEVICE_ID={sys.argv[2]} was not found among connected mobile devices")
        sys.exit(0)

if selected is None:
    selected = mobile[0]
name = selected.get("name") or selected.get("id")
platform = selected.get("targetPlatform") or "unknown"
print(f"OK\t{selected['id']}\t{name}\t{platform}")
PY
}

run_backend_script() {
  local action="$1"
  local log_file exit_code=0 message
  log_file=$(component_log_file backend)
  case "${action}" in
    start)
      write_component_status backend launching '' 'starting backend'
      if "${SCRIPT_DIR}/dev-up.sh" $(scene_args) >>"${log_file}" 2>&1; then
        if backend_is_running; then
          write_component_status backend running 0 'backend running'
          return 0
        fi
        message='backend script finished but container is not running'
        write_component_status backend failed 1 "${message}"
        register_failed_task backend "${action}" "${message}" "${log_file}"
        log_note ERROR "${message}"
        return 1
      fi
      ;;
    stop)
      write_component_status backend launching '' 'stopping backend'
      if "${SCRIPT_DIR}/dev-down.sh" $(scene_args) >>"${log_file}" 2>&1; then
        write_component_status backend stopped 0 'backend stopped'
        return 0
      fi
      ;;
    restart)
      write_component_status backend launching '' 'restarting backend'
      if "${SCRIPT_DIR}/dev-restart.sh" $(scene_args) >>"${log_file}" 2>&1; then
        if backend_is_running; then
          write_component_status backend running 0 'backend running'
          return 0
        fi
        message='backend restart finished but container is not running'
        write_component_status backend failed 1 "${message}"
        register_failed_task backend "${action}" "${message}" "${log_file}"
        log_note ERROR "${message}"
        return 1
      fi
      ;;
  esac
  exit_code=$?
  message="${action} failed, see ${log_file}"
  write_component_status backend failed "${exit_code}" "${message}"
  register_failed_task backend "${action}" "${message}" "${log_file}"
  log_note ERROR "Backend ${action} 失败，exit=${exit_code}，日志: ${log_file}"
  return "${exit_code}"
}

start_backend() { run_backend_script start; }
stop_backend() { run_backend_script stop; }
restart_backend() { run_backend_script restart; }

start_desktop_server() {
  local cmd=("${SCRIPT_DIR}/run-desktop-server.sh")
  [[ "${SCENE}" == 'release' ]] && cmd+=(--release)
  launch_managed_component desktop_server "${cmd[@]}"
  wait_for_component_settle desktop_server start 4
}

start_cli_build() {
  local cmd=("${SCRIPT_DIR}/build-sirix-cli.sh")
  [[ "${SCENE}" == 'release' ]] && cmd+=(--release)
  launch_managed_component cli_build "${cmd[@]}"
  wait_for_component_settle cli_build start 2
}

start_desktop_client() {
  local cmd=("${SCRIPT_DIR}/run-desktop-client.sh")
  local desktop_server_port
  [[ "${SCENE}" == 'release' ]] && cmd+=(--release)

  if ! desktop_server_port=$(ensure_desktop_server_ready_for_flutter); then
    write_component_status desktop_client failed 1 'desktop-server not ready'
    set_notice 'Desktop Server 未就绪，已阻止 Desktop Client 启动。' ERROR
    return 1
  fi

  log_note INFO "Desktop Server 已就绪(port=${desktop_server_port})，开始启动 Desktop Client。"
  launch_managed_component desktop_client "${cmd[@]}"
  wait_for_component_settle desktop_client start 4
}

start_mobile_client() {
  local device_info status device_id device_name platform
  device_info=$(mobile_device_info)
  IFS=$'\t' read -r status device_id device_name platform <<EOF_INFO
${device_info}
EOF_INFO

  if [[ "${status}" == 'NONE' || "${status}" == 'ERR' ]]; then
    write_component_status mobile_client stopped '' "skipped: ${device_id}"
    write_component_meta mobile_client "reason=${device_id}"
    log_note WARN "跳过 Mobile Client 启动：${device_id}"
    return 0
  fi

  local cmd=("${SCRIPT_DIR}/run-mobile-client.sh")
  [[ "${SCENE}" == 'release' ]] && cmd+=(--release)
  cmd+=(-- -d "${device_id}")
  write_component_meta mobile_client "device_id=${device_id}
device_name=${device_name}
platform=${platform}"
  log_note INFO "准备启动 Mobile Client，设备: ${device_name} (${device_id}, ${platform})"
  launch_managed_component mobile_client "${cmd[@]}"
  wait_for_component_settle mobile_client start 4
}

stop_desktop_server() { kill_managed_component desktop_server; }
stop_cli_build() { kill_managed_component cli_build; }
stop_desktop_client() { kill_managed_component desktop_client; }
stop_mobile_client() { kill_managed_component mobile_client; }
restart_desktop_server() { stop_desktop_server; start_desktop_server; }
restart_cli_build() { stop_cli_build; start_cli_build; }
restart_desktop_client() { stop_desktop_client; start_desktop_client; }
restart_mobile_client() { stop_mobile_client; start_mobile_client; }

emit_current_failure_entries() {
  local component state exit_code message updated_at log_file
  for component in backend desktop_server cli_build desktop_client mobile_client; do
    state=$(read_status_value "${component}" state 2>/dev/null || true)
    exit_code=$(read_status_value "${component}" exit_code 2>/dev/null || true)
    message=$(read_status_value "${component}" message 2>/dev/null || true)
    updated_at=$(read_status_value "${component}" updated_at 2>/dev/null || true)
    log_file=$(read_meta_value "${component}" log_file 2>/dev/null || component_log_file "${component}")

    if [[ "${state}" == 'failed' || ( "${state}" == 'stopped' && -n "${exit_code}" && "${exit_code}" != '0' ) ]]; then
      [[ -n "${updated_at}" ]] || updated_at=$(date '+%Y-%m-%d %H:%M:%S')
      [[ -n "${message}" ]] || message="exit ${exit_code}, see ${log_file}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${updated_at}" \
        "${component}" \
        "$(component_label "${component}")" \
        "current-status" \
        "${message}" \
        "${log_file}"
    fi
  done
}

load_recent_failed_entries() {
  local -a entries=()
  local line

  while IFS= read -r line; do
    [[ -n "${line}" ]] && entries+=("${line}")
  done < "${FAILURE_HISTORY_FILE}"

  while IFS= read -r line; do
    [[ -n "${line}" ]] && entries+=("${line}")
  done < <(emit_current_failure_entries)

  if [[ ${#entries[@]} -eq 0 ]]; then
    return 1
  fi

  local start=0 idx
  if (( ${#entries[@]} > 10 )); then
    start=$((${#entries[@]} - 10))
  fi
  for ((idx=${#entries[@]}-1; idx>=start; idx--)); do
    printf '%s\n' "${entries[$idx]}"
  done
}

print_recent_failed_tasks() {
  if ! load_recent_failed_entries >/tmp/sirix-tui-failed-entries.$$ 2>/dev/null; then
    printf '最近没有失败任务记录。\n'
    return 1
  fi

  printf '最近失败的 10 个任务：\n\n'
  awk -F '\t' '{ printf "[%d] %s | %s | %s | %s\n", NR, $1, $3, $4, $5 }' /tmp/sirix-tui-failed-entries.$$
  rm -f /tmp/sirix-tui-failed-entries.$$
}

open_failed_task_log() {
  if ! load_recent_failed_entries >/tmp/sirix-tui-failed-entries.$$ 2>/dev/null; then
    set_notice '最近没有失败任务记录。' INFO
    return 0
  fi

  local -a recent_entries=()
  local line
  while IFS= read -r line; do
    recent_entries+=("${line}")
  done < /tmp/sirix-tui-failed-entries.$$
  rm -f /tmp/sirix-tui-failed-entries.$$

  if supports_interactive_tty; then
    clear >/dev/null 2>&1 || true
  fi
  printf '=== Failed Task Logs ===\n\n'
  print_recent_failed_tasks || true
  printf '\n'

  local choice
  read -r -p '输入序号查看日志，直接回车返回首页: ' choice || return 0
  [[ -z "${choice}" ]] && return 0
  if [[ ! "${choice}" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#recent_entries[@]} )); then
    set_notice '无效序号，已返回首页。' WARN
    return 0
  fi

  local selected timestamp component label action message snapshot_path
  selected="${recent_entries[$((choice - 1))]}"
  IFS=$'\t' read -r timestamp component label action message snapshot_path <<EOF_ENTRY
${selected}
EOF_ENTRY

  if supports_interactive_tty; then
    clear >/dev/null 2>&1 || true
  fi
  printf '=== Failed Task Log ===\n\n'
  printf '时间   : %s\n' "${timestamp}"
  printf '组件   : %s\n' "${label}"
  printf '动作   : %s\n' "${action}"
  printf '说明   : %s\n' "${message}"
  printf '日志文件: %s\n' "${snapshot_path}"
  printf '\n'
  if [[ -f "${snapshot_path}" ]]; then
    cat "${snapshot_path}"
  else
    printf '[log missing] %s\n' "${snapshot_path}"
  fi
  printf '\n'
  read -r -p '日志输出结束，按回车返回首页...' _ || true
}

clear_logs() {
  log_note INFO '开始清理日志...'
  sirix_clear_runtime_logs_for_scene "${BACKEND_DEPLOY_DIR}" "${SCENE}"
  mkdir -p "${LOG_DIR}" "${SIRIX_HOME}/runtime/logs"
  find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
  find "${SIRIX_HOME}/runtime/logs" -type f -name '*.log' -delete 2>/dev/null || true
  write_component_status backend stopped '' 'logs cleared'
  log_note INFO '日志清理完成。'
}

expand_selection_to_ops() {
  local raw="$1"
  local index char
  for ((index = 0; index < ${#raw}; index++)); do
    char="${raw:index:1}"
    case "${char}" in
      1) printf '%s\n' 'backend:start' ;;
      2) printf '%s\n' 'desktop_server:start' ;;
      3) printf '%s\n' 'cli_build:start' ;;
      4) printf '%s\n' 'desktop_client:start' ;;
      5) printf '%s\n' 'mobile_client:start' ;;
      6) printf '%s\n' 'backend:stop' ;;
      7) printf '%s\n' 'desktop_server:stop' ;;
      8) printf '%s\n' 'desktop_client:stop' ;;
      9) printf '%s\n' 'mobile_client:stop' ;;
      A) printf '%s\n' 'cli_build:stop' ;;
      B) printf '%s\n' 'backend:restart' ;;
      C) printf '%s\n' 'desktop_server:restart' ;;
      D) printf '%s\n' 'cli_build:restart' ;;
      E) printf '%s\n' 'desktop_client:restart' ;;
      F) printf '%s\n' 'mobile_client:restart' ;;
      L) printf '%s\n' 'special:clear_logs' ;;
      O)
        printf '%s\n' 'backend:start' 'desktop_server:start' 'cli_build:start' 'desktop_client:start' 'mobile_client:start'
        ;;
      X)
        printf '%s\n' 'backend:stop' 'desktop_server:stop' 'cli_build:stop' 'desktop_client:stop' 'mobile_client:stop'
        ;;
      R)
        printf '%s\n' 'backend:restart' 'desktop_server:restart' 'cli_build:restart' 'desktop_client:restart' 'mobile_client:restart'
        ;;
      S) printf '%s\n' 'special:refresh' ;;
      V) printf '%s\n' 'special:view_failures' ;;
      Q) printf '%s\n' 'special:quit' ;;
      '') ;;
      *)
        log_note WARN "忽略未知指令: ${char}"
        ;;
    esac
  done
}

validate_no_conflicts() {
  local -a ops=("$@")
  local seen_table='' entry component op existing_op
  for entry in "${ops[@]}"; do
    component=${entry%%:*}
    op=${entry##*:}
    [[ "${component}" == 'special' ]] && continue
    existing_op=$(printf '%s' "${seen_table}" | awk -F '=' -v wanted="${component}" '$1 == wanted { print $2; exit }')
    if [[ -n "${existing_op}" && "${existing_op}" != "${op}" ]]; then
      set_notice "检测到冲突：$(component_label "${component}") 同时出现 ${existing_op} 和 ${op}。本次批处理已取消。" WARN
      log_note WARN "检测到冲突：$(component_label "${component}") 同时出现 ${existing_op} 和 ${op}。本次批处理已取消。"
      return 1
    fi
    if [[ -z "${existing_op}" ]]; then
      seen_table+="${component}=${op}"$'\n'
    fi
  done
}

run_named_operation() {
  local component="$1"
  local op="$2"
  case "${component}:${op}" in
    backend:start) start_backend ;;
    backend:stop) stop_backend ;;
    backend:restart) restart_backend ;;
    desktop_server:start) start_desktop_server ;;
    desktop_server:stop) stop_desktop_server ;;
    desktop_server:restart) restart_desktop_server ;;
    cli_build:start) start_cli_build ;;
    cli_build:stop) stop_cli_build ;;
    cli_build:restart) restart_cli_build ;;
    desktop_client:start) start_desktop_client ;;
    desktop_client:stop) stop_desktop_client ;;
    desktop_client:restart) restart_desktop_client ;;
    mobile_client:start) start_mobile_client ;;
    mobile_client:stop) stop_mobile_client ;;
    mobile_client:restart) restart_mobile_client ;;
    *)
      log_note WARN "未实现操作: ${component}:${op}"
      return 1
      ;;
  esac
}

execute_parallel_ops() {
  local -a ops=("$@")
  local -a pids=() labels=() failures=()
  local entry component op pid
  for entry in "${ops[@]}"; do
    component=${entry%%:*}
    op=${entry##*:}
    (
      run_named_operation "${component}" "${op}"
    ) &
    pids+=("$!")
    labels+=("$(component_label "${component}") ${op}")
  done

  local exit_code=0 index=0
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      exit_code=1
      failures+=("${labels[$index]}")
    fi
    index=$((index + 1))
  done

  if (( exit_code == 0 )); then
    set_notice '批处理已完成，状态已自动刷新。' SUCCESS
  else
    set_notice "部分操作失败：${failures[*]}。请查看对应状态和日志。" WARN
  fi
  return "${exit_code}"
}

main_loop() {
  init_colors
  init_command_history
  while true; do
    if supports_interactive_tty; then
      clear >/dev/null 2>&1 || true
    fi
    printf '=== Sirix Dev TUI ===\n\n'
    print_notice
    print_status_table
    print_menu

    local raw_selection selection expanded_op wants_quit wants_clear wants_refresh wants_view_failures
    raw_selection=$(read_command_input) || exit 0
    selection=$(normalize_selection "${raw_selection}")
    [[ -z "${selection}" ]] && continue
    remember_command_history "${raw_selection}"

    local -a expanded_ops=()
    local expanded_ops_count=0
    while IFS= read -r expanded_op; do
      if [[ -n "${expanded_op}" ]]; then
        expanded_ops+=("${expanded_op}")
        expanded_ops_count=$((expanded_ops_count + 1))
      fi
    done < <(expand_selection_to_ops "${selection}")
    [[ "${expanded_ops_count}" -eq 0 ]] && continue

    wants_quit=false
    wants_clear=false
    wants_refresh=false
    wants_view_failures=false
    local -a component_ops=()
    local component_ops_count=0
    local entry component op
    for entry in "${expanded_ops[@]+"${expanded_ops[@]}"}"; do
      component=${entry%%:*}
      op=${entry##*:}
      if [[ "${component}" == 'special' ]]; then
        case "${op}" in
          quit) wants_quit=true ;;
          clear_logs) wants_clear=true ;;
          refresh) wants_refresh=true ;;
          view_failures) wants_view_failures=true ;;
        esac
        continue
      fi
      component_ops+=("${entry}")
      component_ops_count=$((component_ops_count + 1))
    done

    if [[ "${wants_quit}" == true ]]; then
      log_note INFO '退出 Sirix Dev TUI。'
      break
    fi

    if [[ "${component_ops_count}" -gt 0 ]] && ! validate_no_conflicts "${component_ops[@]+"${component_ops[@]}"}"; then
      continue
    fi

    local has_start_like=false has_stop_only=true
    for entry in "${component_ops[@]+"${component_ops[@]}"}"; do
      op=${entry##*:}
      case "${op}" in
        start|restart)
          has_start_like=true
          has_stop_only=false
          ;;
        stop)
          ;;
      esac
    done

    if [[ "${wants_clear}" == true && ( "${has_start_like}" == true || "${component_ops_count}" -eq 0 ) ]]; then
      clear_logs
      set_notice '日志已清理。' SUCCESS
    fi

    if [[ "${component_ops_count}" -gt 0 ]]; then
      execute_parallel_ops "${component_ops[@]+"${component_ops[@]}"}" || true
    elif [[ "${wants_refresh}" == true ]]; then
      set_notice '状态已刷新。' INFO
    fi

    if [[ "${wants_clear}" == true && "${component_ops_count}" -gt 0 && "${has_stop_only}" == true ]]; then
      clear_logs
      set_notice '停止动作完成后已清理日志。' SUCCESS
    fi

    if [[ "${wants_view_failures}" == true ]]; then
      open_failed_task_log
    fi
  done
}

main_loop
