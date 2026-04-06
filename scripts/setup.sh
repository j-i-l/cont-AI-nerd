#!/usr/bin/env bash
# setup.sh — cont-ai-nerd: rootful podman deployment
# =========================================================================
# Idempotent setup script. Safe to re-run at any time to converge to the
# desired state.  Every step is a no-op when the system already matches.
#
# What it does:
#   0. Checks for config.json (runs configure.sh if missing)
#   1. Creates the 'agent' system user
#   2. Ensures project directory traversal permissions (g+x)
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

# shellcheck source-path=SCRIPTDIR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Directory layout
CONTAINER_DIR="${REPO_ROOT}/container"
SYSTEMD_DIR="${REPO_ROOT}/systemd"
LIB_DIR="${REPO_ROOT}/lib"

# Shared template-rendering functions
# shellcheck source=../lib/render-template.sh
source "${LIB_DIR}/render-template.sh"

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

# The agent inside the container shares the primary user's group (mapped GID).
# This allows the agent to read/write files without a dedicated shared group.
PRIMARY_GROUP=$(id -gn "$PRIMARY_USER")
PRIMARY_GID=$(id -g "$PRIMARY_USER")

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
echo "  Primary group : ${PRIMARY_GROUP} (GID: ${PRIMARY_GID})"
echo "  Agent user    : ${AGENT_USER}"
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

# ── Update config.json with path_map ─────────────────────────────────────
# The entrypoint wrapper reads path_map to create symlinks from host paths
# to their /workspace equivalents inside the container.
info "Adding path_map to config.json..."
PATH_MAP_JSON="{"
first=true
for p in "${PROJECT_PATHS[@]}"; do
  $first || PATH_MAP_JSON+=","
  first=false
  PATH_MAP_JSON+="$(printf '"%s":"%s"' "$p" "${CONTAINER_PATHS[$p]}")"
done
PATH_MAP_JSON+="}"

jq --argjson pm "$PATH_MAP_JSON" '.path_map = $pm' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
chown "${PRIMARY_USER}:" "$CONFIG_FILE"
chmod 640 "$CONFIG_FILE"
echo "    path_map: ${PATH_MAP_JSON}"

# ── 1. Identity provisioning ─────────────────────────────────────────────
echo "==> [1/8] Provisioning identity..."

if ! id "${AGENT_USER}" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin "${AGENT_USER}"
  echo "    Created system user: ${AGENT_USER}"
else
  echo "    User ${AGENT_USER} already exists."
fi

AGENT_UID=$(id -u "${AGENT_USER}")
echo "    agent UID=${AGENT_UID}  primary GID=${PRIMARY_GID} (${PRIMARY_GROUP})"

# ── 2. Project directory permissions ─────────────────────────────────────
echo ""
echo "==> [2/8] Configuring project directory permissions..."

for PROJECT_PATH in "${PROJECT_PATHS[@]}"; do
  if [[ ! -d "$PROJECT_PATH" ]]; then
    mkdir -p "$PROJECT_PATH"
    chown "${PRIMARY_USER}:" "$PROJECT_PATH"
    echo "    Created ${PROJECT_PATH}"
  fi

  # Ensure directories are group-traversable (g+x) so the agent can
  # navigate via the mapped GID. File permissions are left as-is —
  # the primary user's default umask determines agent access.
  find "$PROJECT_PATH" -type d ! -perm -g+x -exec chmod g+x {} +
  echo "    Ensured g+x on directories in ${PROJECT_PATH}"
done

# ── 3. cont-ai-nerd config & opencode.json policy ────────────────────────
echo ""
echo "==> [3/8] Generating cont-ai-nerd config..."

mkdir -p "${CONTAINERD_CONFIG}"
chown "${PRIMARY_USER}:" "${CONTAINERD_CONFIG}"
chmod 750 "${CONTAINERD_CONFIG}"

# Generate external_directory policy — allows the agent to access exactly
# the paths that are bind-mounted into the container (using container-side paths).
POLICY_FILE="${CONTAINERD_CONFIG}/opencode.json"
{
  echo '{'
  # shellcheck disable=SC2016 # $schema is a literal JSON key, not a variable
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
chown "${PRIMARY_USER}:" "${POLICY_FILE}"
chmod 640 "${POLICY_FILE}"
echo "    Generated ${POLICY_FILE}"

# ── 4. Ensure host OpenCode config/data directories exist ─────────────────
echo ""
echo "==> [4/8] Ensuring OpenCode config & data directories exist..."

for dir in \
  "${PRIMARY_HOME}/.config/opencode" \
  "${PRIMARY_HOME}/.local/share/opencode" \
  "${PRIMARY_HOME}/.local/share/opencode/log"; do
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    echo "    Created ${dir}"
  else
    echo "    ${dir} exists."
  fi
  chown "${PRIMARY_USER}:" "$dir"
  chmod 750 "$dir"
done

# Ensure auth.json exists (required for bind mount, even if empty)
AUTH_FILE="${PRIMARY_HOME}/.local/share/opencode/auth.json"
if [[ ! -f "$AUTH_FILE" ]]; then
  echo '{}' > "$AUTH_FILE"
  echo "    Created ${AUTH_FILE} (placeholder)"
fi
chown "${PRIMARY_USER}:" "$AUTH_FILE"
chmod 640 "$AUTH_FILE"

# ── 5. Build the container image ─────────────────────────────────────────
echo ""
echo "==> [5/8] Building container image..."

podman build \
  --build-arg "AGENT_UID=${AGENT_UID}" \
  --build-arg "AGENT_GID=${PRIMARY_GID}" \
  --build-arg "AGENT_GROUP_NAME=${PRIMARY_GROUP}" \
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
HOST_PATHS=""
CONT_PATHS=""
for p in "${PROJECT_PATHS[@]}"; do
  HOST_PATHS+="${p}"$'\n'
  CONT_PATHS+="${CONTAINER_PATHS[$p]}"$'\n'
done
HOST_PATHS="${HOST_PATHS%$'\n'}"
CONT_PATHS="${CONT_PATHS%$'\n'}"
VOLUME_LINES=$(build_volume_lines "$HOST_PATHS" "$CONT_PATHS")

render_container_unit \
  "${SYSTEMD_DIR}/cont-ai-nerd.container.in" \
  "${PRIMARY_HOME}" \
  "${CONTAINERD_CONFIG}" \
  "${HOST}" \
  "${PORT}" \
  "${VOLUME_LINES}" \
  > "${QUADLET_DIR}/cont-ai-nerd.container"

echo "    Installed ${QUADLET_DIR}/cont-ai-nerd.container"

# --- Watcher service ---
WATCH_DIRS_ESCAPED=""
for p in "${PROJECT_PATHS[@]}"; do
  WATCH_DIRS_ESCAPED+="${p} "
done
WATCH_DIRS_ESCAPED="${WATCH_DIRS_ESCAPED% }"

render_watcher_unit \
  "${SYSTEMD_DIR}/cont-ai-nerd-watcher.service.in" \
  "${INSTALL_DIR}" \
  "${PRIMARY_USER}" \
  "${AGENT_USER}" \
  "${WATCH_DIRS_ESCAPED}" \
  > /etc/systemd/system/cont-ai-nerd-watcher.service

echo "    Installed cont-ai-nerd-watcher.service"

# --- Commit service ---
render_commit_service \
  "${SYSTEMD_DIR}/cont-ai-nerd-commit.service" \
  "${INSTALL_DIR}" \
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
