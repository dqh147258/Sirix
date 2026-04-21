#!/usr/bin/env bash

# Shared scene helpers for Sirix launcher scripts.
# These helpers centralize the canonical Debug/Release defaults so script entry
# points, compose wrappers, and runtime launchers all derive the same values.

sirix_default_scene() {
  printf '%s\n' "debug"
}

sirix_opposite_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "release" ;;
    release) printf '%s\n' "debug" ;;
    *)
      echo "unsupported scene for opposite lookup: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_resolve_scene_from_env() {
  local raw="${SIRIX_SCENE:-}"
  case "${raw}" in
    release) printf '%s\n' "release" ;;
    ""|debug) printf '%s\n' "debug" ;;
    *)
      echo "unsupported SIRIX_SCENE: ${raw}" >&2
      return 1
      ;;
  esac
}

sirix_home_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "${HOME}/.sirix-debug" ;;
    release) printf '%s\n' "${HOME}/.sirix" ;;
    *)
      echo "unsupported scene for home: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_workspace_dirname_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' ".sirix-debug" ;;
    release) printf '%s\n' ".sirix" ;;
    *)
      echo "unsupported scene for workspace dir: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_backend_port_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "46110" ;;
    release) printf '%s\n' "46120" ;;
    *)
      echo "unsupported scene for backend port: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_desktop_port_start_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "46111" ;;
    release) printf '%s\n' "46121" ;;
    *)
      echo "unsupported scene for desktop ws start: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_desktop_port_end_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "46119" ;;
    release) printf '%s\n' "46129" ;;
    *)
      echo "unsupported scene for desktop ws end: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_compose_project_name_for_scene() {
  local scene="$1"
  printf 'sirix-%s\n' "${scene}"
}

sirix_compose_env_file_for_scene() {
  local deploy_dir="$1"
  local scene="$2"
  printf '%s/.env.%s\n' "${deploy_dir}" "${scene}"
}

sirix_compose_runtime_logs_dir_for_scene() {
  local deploy_dir="$1"
  local scene="$2"
  printf '%s/runtime-logs/%s\n' "${deploy_dir}" "${scene}"
}

sirix_runtime_logs_root_dir() {
  local deploy_dir="$1"
  printf '%s/runtime-logs\n' "${deploy_dir}"
}

sirix_apply_scene_default_env() {
  local var_name="$1"
  local desired_value="$2"
  local opposite_value="${3:-}"
  local current_value="${!var_name-}"

  # `--release` / default-debug should reliably switch the canonical scene
  # values even when the current shell inherited Debug/Release exports from a
  # previous Sirix terminal. Custom non-canonical overrides must still win, so
  # only empty values or the opposite scene's canonical default are replaced.
  if [[ -z "${current_value}" || ( -n "${opposite_value}" && "${current_value}" == "${opposite_value}" ) ]]; then
    printf -v "${var_name}" '%s' "${desired_value}"
  fi
  export "${var_name}"
}

sirix_postgres_host_port_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "46210" ;;
    release) printf '%s\n' "46220" ;;
    *)
      echo "unsupported scene for postgres host port: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_redis_host_port_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "46211" ;;
    release) printf '%s\n' "46221" ;;
    *)
      echo "unsupported scene for redis host port: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_turn_host_port_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "46212" ;;
    release) printf '%s\n' "46222" ;;
    *)
      echo "unsupported scene for coturn host port: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_turn_relay_host_start_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "46213" ;;
    release) printf '%s\n' "46223" ;;
    *)
      echo "unsupported scene for coturn relay start: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_turn_relay_host_end_for_scene() {
  local scene="$1"
  case "${scene}" in
    debug) printf '%s\n' "46218" ;;
    release) printf '%s\n' "46228" ;;
    *)
      echo "unsupported scene for coturn relay end: ${scene}" >&2
      return 1
      ;;
  esac
}

sirix_export_scene_env() {
  local scene="$1"
  local deploy_dir="${2:-}"
  local opposite_scene

  opposite_scene="$(sirix_opposite_scene "${scene}")"

  export SIRIX_SCENE="${scene}"
  sirix_apply_scene_default_env \
    SIRIX_HOME \
    "$(sirix_home_for_scene "${scene}")" \
    "$(sirix_home_for_scene "${opposite_scene}")"
  sirix_apply_scene_default_env \
    SIRIX_WORKSPACE_CONFIG_DIRNAME \
    "$(sirix_workspace_dirname_for_scene "${scene}")" \
    "$(sirix_workspace_dirname_for_scene "${opposite_scene}")"
  sirix_apply_scene_default_env \
    SIRIX_DESKTOP_SERVER_PORT_START \
    "$(sirix_desktop_port_start_for_scene "${scene}")" \
    "$(sirix_desktop_port_start_for_scene "${opposite_scene}")"
  sirix_apply_scene_default_env \
    SIRIX_DESKTOP_SERVER_PORT_END \
    "$(sirix_desktop_port_end_for_scene "${scene}")" \
    "$(sirix_desktop_port_end_for_scene "${opposite_scene}")"
  sirix_apply_scene_default_env \
    BACKEND_PORT \
    "$(sirix_backend_port_for_scene "${scene}")" \
    "$(sirix_backend_port_for_scene "${opposite_scene}")"

  if [[ -n "${deploy_dir}" ]]; then
    sirix_apply_scene_default_env \
      COMPOSE_PROJECT_NAME \
      "$(sirix_compose_project_name_for_scene "${scene}")" \
      "$(sirix_compose_project_name_for_scene "${opposite_scene}")"
    sirix_apply_scene_default_env \
      RUNTIME_LOGS_HOST_DIR \
      "$(sirix_compose_runtime_logs_dir_for_scene "${deploy_dir}" "${scene}")" \
      "$(sirix_compose_runtime_logs_dir_for_scene "${deploy_dir}" "${opposite_scene}")"
  fi
}

sirix_export_dependency_host_ports() {
  local scene="$1"
  local opposite_scene

  opposite_scene="$(sirix_opposite_scene "${scene}")"

  sirix_apply_scene_default_env \
    POSTGRES_HOST_PORT \
    "$(sirix_postgres_host_port_for_scene "${scene}")" \
    "$(sirix_postgres_host_port_for_scene "${opposite_scene}")"
  sirix_apply_scene_default_env \
    REDIS_HOST_PORT \
    "$(sirix_redis_host_port_for_scene "${scene}")" \
    "$(sirix_redis_host_port_for_scene "${opposite_scene}")"
  sirix_apply_scene_default_env \
    TURN_HOST_PORT \
    "$(sirix_turn_host_port_for_scene "${scene}")" \
    "$(sirix_turn_host_port_for_scene "${opposite_scene}")"
  sirix_apply_scene_default_env \
    TURN_RELAY_HOST_START \
    "$(sirix_turn_relay_host_start_for_scene "${scene}")" \
    "$(sirix_turn_relay_host_start_for_scene "${opposite_scene}")"
  sirix_apply_scene_default_env \
    TURN_RELAY_HOST_END \
    "$(sirix_turn_relay_host_end_for_scene "${scene}")" \
    "$(sirix_turn_relay_host_end_for_scene "${opposite_scene}")"
}

sirix_install_exec_shim() {
  local source="$1"
  local target="$2"
  local scene="$3"
  local sirix_home="$4"

  rm -f "${target}"
  cat >"${target}" <<EOF
#!/usr/bin/env bash
export SIRIX_SCENE="${scene}"
export SIRIX_HOME="${sirix_home}"
exec "${source}" "\$@"
EOF
  chmod +x "${target}"
}

sirix_clear_runtime_logs_for_scene() {
  local deploy_dir="$1"
  local scene="$2"
  local logs_root
  local scene_logs_dir
  logs_root="$(sirix_runtime_logs_root_dir "${deploy_dir}")"
  scene_logs_dir="$(sirix_compose_runtime_logs_dir_for_scene "${deploy_dir}" "${scene}")"

  mkdir -p "${logs_root}"
  rm -rf "${scene_logs_dir}"
  mkdir -p "${scene_logs_dir}"
}
