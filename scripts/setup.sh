#!/usr/bin/env bash
# setup.sh — cont-ai-nerd: rootful podman deployment
# =========================================================================
# Idempotent setup script. Safe to re-run at any time to converge to the
# desired state.  Every step is a no-op when the system already matches.
#
# What it does:
#   0. Checks for config.json (runs configure.sh if missing)
#   1. Creates the 'agent' system user and 'ai' group
#   2. Configures project directory permissions (setgid, group-write)
#   3. Creates the cont-ai-nerd config dir and generates opencode.json policy
#   4. Ensures OpenCode host config/data directories exist
#   5. Builds the container image
#   6. Installs helper scripts
#   7. Renders and installs systemd units (quadlet + watcher + commit timer)
#   8. Activates all services
#
# Usage:
#   sudo ./setup.sh
#
# Configuration:
#   All settings are read from ~/.config/cont-ai-nerd/config.json
#   Run ./configure.sh first to create the configuration file, or
#   setup.sh will invoke it automatically if no config exists.
#
# Examples:
#   sudo ./configure.sh                       # create config first
#   sudo ./setup.sh                           # run setup
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Directory layout
CONTAINER_DIR="${REPO_ROOT}/container"
SYSTEMD_DIR="${REPO_ROOT}/systemd"
LIB_DIR="${REPO_ROOT}/lib"

# ── Colors (if terminal supports them) ───────────────────────────────────
if [[ -t 1 ]]; then
  BOLD='\033[1m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  RESET='\033[0m'
else
  BOLD='' GREEN='' YELLOW='' RED='' RESET=''
fi

# ── Helper functions ─────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Path mapping functions ───────────────────────────────────────────────
# These compute container-side paths under /workspace by stripping the
# common parent directory from all project paths.
#
# Example: /home/alice/Projects, /home/alice/work
#   → common parent: /home/alice
#   → container paths: /workspace/Projects, /workspace/work

# find_common_parent: Find the longest common directory prefix of all paths.
# Usage: find_common_parent "/path/a" "/path/b" ...
# Output: The common parent directory (e.g., "/path")
find_common_parent() {
  local -a paths=("$@")
  [[ ${#paths[@]} -eq 0 ]] && return 1
  
  # Start with the first path's directory components
  local common="${paths[0]}"
  
  for path in "${paths[@]:1}"; do
    # Reduce common prefix until it matches the current path
    while [[ "${path}" != "${common}"* ]]; do
      # Remove the last component from common
      common="${common%/*}"
      [[ -z "$common" ]] && common="/"
      [[ "$common" == "/" ]] && break
    done
  done
  
  echo "$common"
}

# get_container_path: Convert a host path to its container-side equivalent.
# Usage: get_container_path "/home/alice/Projects" "/home/alice"
# Output: /workspace/Projects
get_container_path() {
  local host_path="$1"
  local common_parent="$2"
  
  if [[ "$common_parent" == "/" ]]; then
    # No common parent other than root — use full path under /workspace
    echo "/workspace${host_path}"
  elif [[ "$host_path" == "$common_parent" ]]; then
    # Single path case: host_path equals common_parent, use basename
    # e.g., /home/alice/Projects → /workspace/Projects
    echo "/workspace/$(basename "$host_path")"
  else
    # Strip the common parent to get the unique suffix
    local suffix="${host_path#"$common_parent"}"
    # Ensure suffix starts with /
    [[ "$suffix" != /* ]] && suffix="/${suffix}"
    echo "/workspace${suffix}"
  fi
}

# ── Root check ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (sudo ./setup.sh)"
fi

# ── Dependency check ─────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  die "jq is required but not installed. Please install jq first."
fi

# ── Static configuration ─────────────────────────────────────────────────
QUADLET_DIR="/etc/containers/systemd"

# ── Determine config file location ───────────────────────────────────────
# We need to detect the primary user first to find the config file location.
DETECTED_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"

if [[ -z "$DETECTED_USER" ]]; then
  die "Could not detect primary user. Please run with sudo or set SUDO_USER."
fi

DETECTED_HOME=$(eval echo "~${DETECTED_USER}")
CONFIG_FILE="${DETECTED_HOME}/.config/cont-ai-nerd/config.json"

# ── Configuration file handling ──────────────────────────────────────────
run_configure() {
  info "Running configure.sh..."
  "${SCRIPT_DIR}/configure.sh"
  
  # Re-check if config was created
  if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Configuration was not created. Aborting."
  fi
}

if [[ -f "$CONFIG_FILE" ]]; then
  echo ""
  echo -e "${BOLD}Found existing configuration:${RESET} ${CONFIG_FILE}"
  echo ""
  jq '.' "$CONFIG_FILE" | sed 's/^/  /'
  echo ""
  echo -en "Use this configuration? [Y/n/recreate]: "
  read -r response
  response="${response:-Y}"
  
  case "$response" in
    [Yy]|"")
      info "Using existing configuration."
      ;;
    [Rr]|recreate)
      run_configure
      ;;
    *)
      echo "Aborting. Edit the config file manually or run:"
      echo "  sudo ./configure.sh"
      exit 0
      ;;
  esac
else
  warn "Configuration file not found: ${CONFIG_FILE}"
  echo ""
  run_configure
fi

# ── Read configuration ───────────────────────────────────────────────────
info "Reading configuration from ${CONFIG_FILE}..."

PRIMARY_USER=$(jq -r '.primary_user // empty' "$CONFIG_FILE")
PRIMARY_HOME=$(jq -r '.primary_home // empty' "$CONFIG_FILE")
AGENT_USER=$(jq -r '.agent_user // "agent"' "$CONFIG_FILE")
AGENT_GROUP=$(jq -r '.agent_group // "ai"' "$CONFIG_FILE")
HOST=$(jq -r '.host // "127.0.0.1"' "$CONFIG_FILE")
PORT=$(jq -r '.port // 3000' "$CONFIG_FILE")
INSTALL_DIR=$(jq -r '.install_dir // "/opt/cont-ai-nerd"' "$CONFIG_FILE")

# Read project_paths as a bash array
readarray -t PROJECT_PATHS < <(jq -r '.project_paths[]' "$CONFIG_FILE")

# ── Validate configuration ───────────────────────────────────────────────
info "Validating configuration..."

# Required fields
[[ -z "$PRIMARY_USER" ]] && die "Config error: 'primary_user' is required."
[[ -z "$PRIMARY_HOME" ]] && die "Config error: 'primary_home' is required."
[[ ${#PROJECT_PATHS[@]} -eq 0 ]] && die "Config error: 'project_paths' must contain at least one path."

# Validate primary_user exists
if ! id "$PRIMARY_USER" &>/dev/null; then
  die "Config error: User '$PRIMARY_USER' does not exist."
fi

# Validate primary_home exists
if [[ ! -d "$PRIMARY_HOME" ]]; then
  die "Config error: Home directory '$PRIMARY_HOME' does not exist."
fi

# Validate project_paths exist
for path in "${PROJECT_PATHS[@]}"; do
  if [[ ! -d "$path" ]]; then
    die "Config error: Project path '$path' does not exist."
  fi
done

# Validate port
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
  die "Config error: Invalid port number '$PORT'."
fi

# ── Derived values ───────────────────────────────────────────────────────
CONTAINERD_CONFIG="${PRIMARY_HOME}/.config/cont-ai-nerd"

# Compute common parent and container-side paths for /workspace mounts
COMMON_PARENT=$(find_common_parent "${PROJECT_PATHS[@]}")
declare -A CONTAINER_PATHS
for p in "${PROJECT_PATHS[@]}"; do
  CONTAINER_PATHS["$p"]=$(get_container_path "$p" "$COMMON_PARENT")
done

echo ""
echo "================================================================="
echo "  cont-ai-nerd — Podman Setup"
echo "================================================================="
echo "  Primary user  : ${PRIMARY_USER} (home: ${PRIMARY_HOME})"
echo "  Agent user    : ${AGENT_USER}"
echo "  Agent group   : ${AGENT_GROUP}"
echo "  Project paths : ${PROJECT_PATHS[*]}"
echo "  Common parent : ${COMMON_PARENT}"
echo "  Config dir    : ${CONTAINERD_CONFIG}"
echo "  Install dir   : ${INSTALL_DIR}"
echo "  Listen        : ${HOST}:${PORT}"
echo ""
echo "  Container mount mapping:"
for p in "${PROJECT_PATHS[@]}"; do
  echo "    ${p} → ${CONTAINER_PATHS[$p]}"
done
echo "================================================================="
echo ""

# ── 1. Identity & group provisioning ─────────────────────────────────────
echo "==> [1/8] Provisioning identity..."

groupadd -f "${AGENT_GROUP}"

if ! id "${AGENT_USER}" &>/dev/null; then
  useradd -r -g "${AGENT_GROUP}" -s /usr/sbin/nologin "${AGENT_USER}"
  echo "    Created system user: ${AGENT_USER}"
else
  echo "    User ${AGENT_USER} already exists."
fi

usermod -aG "${AGENT_GROUP}" "${PRIMARY_USER}" 2>/dev/null || true
echo "    ${PRIMARY_USER} is a member of group ${AGENT_GROUP}"

AGENT_UID=$(id -u "${AGENT_USER}")
AI_GID=$(getent group "${AGENT_GROUP}" | cut -d: -f3)
echo "    agent UID=${AGENT_UID}  ai GID=${AI_GID}"

# ── 2. Project directory permissions ─────────────────────────────────────
echo ""
echo "==> [2/8] Configuring project directory permissions..."

for PROJECT_PATH in "${PROJECT_PATHS[@]}"; do
  if [[ ! -d "$PROJECT_PATH" ]]; then
    mkdir -p "$PROJECT_PATH"
    chown "${PRIMARY_USER}:${AGENT_GROUP}" "$PROJECT_PATH"
    echo "    Created ${PROJECT_PATH}"
  fi

  # Group ownership → ai; setgid so new entries inherit the group.
  chgrp -R "${AGENT_GROUP}" "$PROJECT_PATH"
  find "$PROJECT_PATH" -type d -exec chmod g+rwxs {} +
  find "$PROJECT_PATH" -type f -exec chmod g+rw {} +
  echo "    Configured ${PROJECT_PATH}  (group=${AGENT_GROUP}, setgid)"
done

# ── 3. cont-ai-nerd config & opencode.json policy ────────────────────────
echo ""
echo "==> [3/8] Generating cont-ai-nerd config..."

mkdir -p "${CONTAINERD_CONFIG}"
chown "${PRIMARY_USER}:${PRIMARY_USER}" "${CONTAINERD_CONFIG}"

# Generate external_directory policy — allows the agent to access exactly
# the paths that are bind-mounted into the container (using container-side paths).
POLICY_FILE="${CONTAINERD_CONFIG}/opencode.json"
{
  echo '{'
  echo '  "$schema": "https://opencode.ai/config.json",'
  echo '  "permission": {'
  echo '    "external_directory": {'
  for i in "${!PROJECT_PATHS[@]}"; do
    comma=$([[ $i -lt $((${#PROJECT_PATHS[@]} - 1)) ]] && echo "," || echo "")
    container_path="${CONTAINER_PATHS[${PROJECT_PATHS[$i]}]}"
    echo "      \"${container_path}/**\": \"allow\"${comma}"
  done
  echo '    }'
  echo '  }'
  echo '}'
} > "${POLICY_FILE}"
chown "${PRIMARY_USER}:${PRIMARY_USER}" "${POLICY_FILE}"
chmod 644 "${POLICY_FILE}"
echo "    Generated ${POLICY_FILE}"

# ── 4. Ensure host OpenCode config/data directories exist ─────────────────
echo ""
echo "==> [4/8] Ensuring OpenCode config & data directories exist..."

for dir in \
  "${PRIMARY_HOME}/.config/opencode" \
  "${PRIMARY_HOME}/.local/share/opencode"; do
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    chown "${PRIMARY_USER}:${PRIMARY_USER}" "$dir"
    echo "    Created ${dir}"
  else
    echo "    ${dir} exists."
  fi
done

# Ensure auth.json exists (required for bind mount, even if empty)
AUTH_FILE="${PRIMARY_HOME}/.local/share/opencode/auth.json"
if [[ ! -f "$AUTH_FILE" ]]; then
  echo '{}' > "$AUTH_FILE"
  chown "${PRIMARY_USER}:${PRIMARY_USER}" "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"
  echo "    Created ${AUTH_FILE} (placeholder)"
fi

# ── 5. Build the container image ─────────────────────────────────────────
echo ""
echo "==> [5/8] Building container image..."

podman build \
  --build-arg "AGENT_UID=${AGENT_UID}" \
  --build-arg "AGENT_GID=${AI_GID}" \
  -t localhost/cont-ai-nerd:latest \
  -f "${CONTAINER_DIR}/Containerfile" \
  "${CONTAINER_DIR}"

echo "    Image built: localhost/cont-ai-nerd:latest"

# ── 6. Install helper scripts ─────────────────────────────────────────────
echo ""
echo "==> [6/8] Installing scripts to ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}"
install -m 755 "${LIB_DIR}/cont-ai-nerd-watcher.sh"  "${INSTALL_DIR}/"
install -m 755 "${LIB_DIR}/cont-ai-nerd-commit.sh"   "${INSTALL_DIR}/"
install -m 755 "${LIB_DIR}/cont-ai-nerd-tui.sh"      "${INSTALL_DIR}/"

# Symlink TUI script to /usr/local/bin for easy access
ln -sf "${INSTALL_DIR}/cont-ai-nerd-tui.sh" /usr/local/bin/cont-ai-nerd-tui
echo "    Installed cont-ai-nerd-tui → /usr/local/bin/cont-ai-nerd-tui"

# ── 7. Render & install systemd units ─────────────────────────────────────
echo ""
echo "==> [7/8] Installing systemd units..."

# --- Quadlet ---
mkdir -p "${QUADLET_DIR}"

# Build the Volume= lines for project paths using /workspace container paths.
VOLUME_LINES=""
for p in "${PROJECT_PATHS[@]}"; do
  container_path="${CONTAINER_PATHS[$p]}"
  VOLUME_LINES+="Volume=${p}:${container_path}:rw,Z"$'\n'
done
# Remove trailing newline for clean substitution.
VOLUME_LINES="${VOLUME_LINES%$'\n'}"

# sed handles scalar placeholders; awk handles the multi-line @@VOLUME_LINES@@.
sed \
  -e "s|@@AGENT_UID@@|${AGENT_UID}|g" \
  -e "s|@@AGENT_GID@@|${AI_GID}|g" \
  -e "s|@@PRIMARY_HOME@@|${PRIMARY_HOME}|g" \
  -e "s|@@CONTAINERD_CONFIG@@|${CONTAINERD_CONFIG}|g" \
  -e "s|@@HOST@@|${HOST}|g" \
  -e "s|@@PORT@@|${PORT}|g" \
  "${SYSTEMD_DIR}/cont-ai-nerd.container.in" | \
  awk -v lines="$VOLUME_LINES" '{gsub(/@@VOLUME_LINES@@/, lines); print}' \
  > "${QUADLET_DIR}/cont-ai-nerd.container"

echo "    Installed ${QUADLET_DIR}/cont-ai-nerd.container"

# --- Watcher service ---
WATCH_DIRS_ESCAPED=""
for p in "${PROJECT_PATHS[@]}"; do
  WATCH_DIRS_ESCAPED+="${p} "
done
WATCH_DIRS_ESCAPED="${WATCH_DIRS_ESCAPED% }"

sed \
  -e "s|@@INSTALL_DIR@@|${INSTALL_DIR}|g" \
  -e "s|@@PRIMARY_USER@@|${PRIMARY_USER}|g" \
  -e "s|@@AGENT_USER@@|${AGENT_USER}|g" \
  -e "s|@@WATCH_DIRS@@|${WATCH_DIRS_ESCAPED}|g" \
  "${SYSTEMD_DIR}/cont-ai-nerd-watcher.service.in" \
  > /etc/systemd/system/cont-ai-nerd-watcher.service

echo "    Installed cont-ai-nerd-watcher.service"

# --- Commit service ---
sed \
  -e "s|@@INSTALL_DIR@@|${INSTALL_DIR}|g" \
  "${SYSTEMD_DIR}/cont-ai-nerd-commit.service" \
  > /etc/systemd/system/cont-ai-nerd-commit.service

echo "    Installed cont-ai-nerd-commit.service"

# --- Commit timer (no templating needed) ---
cp "${SYSTEMD_DIR}/cont-ai-nerd-commit.timer" \
   /etc/systemd/system/cont-ai-nerd-commit.timer

echo "    Installed cont-ai-nerd-commit.timer"

# ── 8. Activate ──────────────────────────────────────────────────────────
echo ""
echo "==> [8/8] Activating services..."

systemctl daemon-reload

# Stop existing instances gracefully before (re)starting.
# These are no-ops on first run (services don't exist yet).
systemctl stop cont-ai-nerd-watcher.service 2>/dev/null || true
systemctl stop cont-ai-nerd.service 2>/dev/null || true

# Quadlet-generated units cannot be "enabled" — they're transient.
# The [Install] section in the .container file handles WantedBy.
# Just start the service; it will auto-start on boot via the generator.
systemctl start cont-ai-nerd.service

# These are regular unit files in /etc/systemd/system, so enable works:
systemctl enable --now cont-ai-nerd-watcher.service
systemctl enable --now cont-ai-nerd-commit.timer

echo ""
echo "================================================================="
echo "  cont-ai-nerd setup complete."
echo ""
echo "  Container : podman ps | grep cont-ai-nerd"
echo "  TUI (rw)  : sudo cont-ai-nerd-tui        # can run /connect"
echo "  TUI (ro)  : podman exec -it cont-ai-nerd opencode-tui"
echo "  Watcher   : systemctl status cont-ai-nerd-watcher"
echo "  Commits   : systemctl list-timers cont-ai-nerd-commit"
echo "  Logs      : journalctl -u cont-ai-nerd -f"
echo "================================================================="
