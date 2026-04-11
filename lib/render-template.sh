#!/usr/bin/env bash
# render-template.sh — shared functions to render systemd unit templates
# =========================================================================
# Sourceable library used by setup.sh and the template-rendering tests.
# All functions read from stdin or a file and write to stdout.
# =========================================================================

# render_container_unit — render contain.container.in
#
# Arguments (named via env vars to keep the interface explicit):
#   $1  template_path   — path to the .container.in template
#   $2  primary_home    — absolute path to the primary user's home directory
#   $3  containerd_config — path to ~/.config/contain on the host
#   $4  host            — listen address (e.g. 127.0.0.1)
#   $5  port            — listen port (e.g. 3000)
#   $6  volume_lines    — pre-built Volume= directives (newline-separated)
#
# Output: rendered unit on stdout
render_container_unit() {
  local template_path="$1"
  local primary_home="$2"
  local containerd_config="$3"
  local host="$4"
  local port="$5"
  local volume_lines="$6"

  sed \
    -e "s|@@PRIMARY_HOME@@|${primary_home}|g" \
    -e "s|@@CONTAINERD_CONFIG@@|${containerd_config}|g" \
    -e "s|@@HOST@@|${host}|g" \
    -e "s|@@PORT@@|${port}|g" \
    "${template_path}" | \
    awk -v lines="$volume_lines" '{gsub(/@@VOLUME_LINES@@/, lines); print}'
}

# render_watcher_unit — render contain-watcher.service.in
#
# Arguments:
#   $1  template_path   — path to the .service.in template
#   $2  install_dir     — directory containing the watcher script
#   $3  primary_user    — login name of the human user
#   $4  agent_user      — login name of the container agent user
#   $5  watch_dirs      — space-separated list of directories to watch
#
# Output: rendered unit on stdout
render_watcher_unit() {
  local template_path="$1"
  local install_dir="$2"
  local primary_user="$3"
  local agent_user="$4"
  local watch_dirs="$5"

  sed \
    -e "s|@@INSTALL_DIR@@|${install_dir}|g" \
    -e "s|@@PRIMARY_USER@@|${primary_user}|g" \
    -e "s|@@AGENT_USER@@|${agent_user}|g" \
    -e "s|@@WATCH_DIRS@@|${watch_dirs}|g" \
    "${template_path}"
}

# render_commit_service — render contain-commit.service
#
# Arguments:
#   $1  template_path   — path to the .service template
#   $2  install_dir     — directory containing the commit script
#
# Output: rendered unit on stdout
render_commit_service() {
  local template_path="$1"
  local install_dir="$2"

  sed \
    -e "s|@@INSTALL_DIR@@|${install_dir}|g" \
    "${template_path}"
}

# build_volume_lines — build Volume= directives from parallel arrays
#
# Arguments:
#   $1  project_paths   — newline-separated list of host paths
#   $2  container_paths — newline-separated list of corresponding container paths
#
# Output: newline-separated Volume= directives (no trailing newline)
build_volume_lines() {
  local -a host_paths
  local -a cont_paths
  IFS=$'\n' read -r -d '' -a host_paths <<< "$1" || true
  IFS=$'\n' read -r -d '' -a cont_paths <<< "$2" || true

  local result=""
  for i in "${!host_paths[@]}"; do
    [[ -n "${host_paths[$i]}" ]] || continue
    result+="Volume=${host_paths[$i]}:${cont_paths[$i]}:rw,Z"$'\n'
  done
  # Remove trailing newline for clean substitution
  echo -n "${result%$'\n'}"
}
