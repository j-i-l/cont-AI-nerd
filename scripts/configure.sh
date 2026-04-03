#!/usr/bin/env bash
# configure.sh — cont-ai-nerd: interactive configuration generator
# =========================================================================
# Creates or updates ~/.config/cont-ai-nerd/config.json with user-provided
# values. This script can be run standalone before setup.sh, or setup.sh
# will invoke it automatically if no config exists.
#
# Usage:
#   sudo ./configure.sh
#
# The configuration file is stored in the primary user's home directory
# with restricted permissions (readable only by root and the primary user).
# =========================================================================
set -euo pipefail

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

# Prompt for input with a default value
# Usage: prompt "Prompt text" "default_value" variable_name
prompt() {
  local prompt_text="$1"
  local default="$2"
  local var_name="$3"
  local input

  if [[ -n "$default" ]]; then
    echo -en "${BOLD}${prompt_text}${RESET} [${default}]: "
  else
    echo -en "${BOLD}${prompt_text}${RESET}: "
  fi

  read -r input
  input="${input:-$default}"

  # Assign to variable name
  printf -v "$var_name" '%s' "$input"
}

# Validate that a user exists on the system
validate_user() {
  local user="$1"
  if ! id "$user" &>/dev/null; then
    return 1
  fi
  return 0
}

# Validate that a directory exists
validate_directory() {
  local dir="$1"
  [[ -d "$dir" ]]
}

# Validate port number (1-65535)
validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

# Parse comma-separated paths into a bash array
parse_paths() {
  local input="$1"
  local -n arr="$2"
  arr=()

  IFS=',' read -ra parts <<< "$input"
  for part in "${parts[@]}"; do
    # Trim whitespace
    part="$(echo "$part" | xargs)"
    # Expand ~ to home directory
    part="${part/#\~/$PRIMARY_HOME}"
    if [[ -n "$part" ]]; then
      arr+=("$part")
    fi
  done
}

# ── Root check ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (sudo ./configure.sh)"
fi

# ── Detect primary user ──────────────────────────────────────────────────
DETECTED_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"

echo ""
echo -e "${BOLD}=================================================================${RESET}"
echo -e "${BOLD}  cont-ai-nerd — Configuration${RESET}"
echo -e "${BOLD}=================================================================${RESET}"
echo ""
echo "This script will create the configuration file for cont-ai-nerd."
echo "Press Enter to accept the default value shown in brackets."
echo ""

# ── Primary user (required) ──────────────────────────────────────────────
while true; do
  prompt "Primary user" "$DETECTED_USER" PRIMARY_USER

  if [[ -z "$PRIMARY_USER" ]]; then
    error "Primary user is required."
    continue
  fi

  if ! validate_user "$PRIMARY_USER"; then
    error "User '$PRIMARY_USER' does not exist on this system."
    continue
  fi

  break
done

# ── Primary home ─────────────────────────────────────────────────────────
DEFAULT_HOME=$(eval echo "~${PRIMARY_USER}")

while true; do
  prompt "Home directory for $PRIMARY_USER" "$DEFAULT_HOME" PRIMARY_HOME

  if [[ -z "$PRIMARY_HOME" ]]; then
    error "Home directory is required."
    continue
  fi

  if ! validate_directory "$PRIMARY_HOME"; then
    error "Directory '$PRIMARY_HOME' does not exist."
    continue
  fi

  break
done

# ── Project paths ────────────────────────────────────────────────────────
DEFAULT_PROJECTS="${PRIMARY_HOME}/Projects"

while true; do
  prompt "Project directories (comma-separated)" "$DEFAULT_PROJECTS" PROJECT_INPUT

  if [[ -z "$PROJECT_INPUT" ]]; then
    error "At least one project directory is required."
    continue
  fi

  # Parse paths
  declare -a PROJECT_PATHS
  parse_paths "$PROJECT_INPUT" PROJECT_PATHS

  if [[ ${#PROJECT_PATHS[@]} -eq 0 ]]; then
    error "At least one project directory is required."
    continue
  fi

  # Validate each path
  all_valid=true
  for path in "${PROJECT_PATHS[@]}"; do
    if ! validate_directory "$path"; then
      warn "Directory '$path' does not exist."
      echo -en "Create it? [Y/n]: "
      read -r create_dir
      create_dir="${create_dir:-Y}"

      if [[ "$create_dir" =~ ^[Yy] ]]; then
        mkdir -p "$path"
        chown "${PRIMARY_USER}:${PRIMARY_USER}" "$path"
        info "Created $path"
      else
        all_valid=false
        break
      fi
    fi
  done

  if $all_valid; then
    break
  fi
done

# ── Agent user ───────────────────────────────────────────────────────────
prompt "Container agent username" "agent" AGENT_USER

if [[ -z "$AGENT_USER" ]]; then
  AGENT_USER="agent"
fi

# ── Agent group ──────────────────────────────────────────────────────────
prompt "Shared group name" "ai" AGENT_GROUP

if [[ -z "$AGENT_GROUP" ]]; then
  AGENT_GROUP="ai"
fi

# ── Host ─────────────────────────────────────────────────────────────────
prompt "Server listen address" "127.0.0.1" HOST

if [[ -z "$HOST" ]]; then
  HOST="127.0.0.1"
fi

# ── Port ─────────────────────────────────────────────────────────────────
while true; do
  prompt "Server listen port" "3000" PORT

  if [[ -z "$PORT" ]]; then
    PORT="3000"
  fi

  if ! validate_port "$PORT"; then
    error "Invalid port number. Must be between 1 and 65535."
    continue
  fi

  break
done

# ── Install directory ────────────────────────────────────────────────────
prompt "Installation directory" "/opt/cont-ai-nerd" INSTALL_DIR

if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="/opt/cont-ai-nerd"
fi

# ── Generate config file ─────────────────────────────────────────────────
CONFIG_DIR="${PRIMARY_HOME}/.config/cont-ai-nerd"
CONFIG_FILE="${CONFIG_DIR}/config.json"

mkdir -p "$CONFIG_DIR"
chown "${PRIMARY_USER}:${PRIMARY_USER}" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

# Build JSON array for project_paths
PROJECT_PATHS_JSON=$(printf '%s\n' "${PROJECT_PATHS[@]}" | jq -R . | jq -s .)

# Generate the config file
cat > "$CONFIG_FILE" <<EOF
{
  "primary_user": "${PRIMARY_USER}",
  "primary_home": "${PRIMARY_HOME}",
  "project_paths": ${PROJECT_PATHS_JSON},
  "agent_user": "${AGENT_USER}",
  "agent_group": "${AGENT_GROUP}",
  "host": "${HOST}",
  "port": ${PORT},
  "install_dir": "${INSTALL_DIR}"
}
EOF

# Set permissions: readable only by root and primary_user
chown "${PRIMARY_USER}:${PRIMARY_USER}" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo ""
echo -e "${BOLD}=================================================================${RESET}"
echo -e "${GREEN}  Configuration saved successfully!${RESET}"
echo -e "${BOLD}=================================================================${RESET}"
echo ""
echo "  Config file: ${CONFIG_FILE}"
echo ""
echo "  Contents:"
jq '.' "$CONFIG_FILE" | sed 's/^/    /'
echo ""
echo "  You can now run setup.sh to complete the installation:"
echo "    sudo ./setup.sh"
echo ""
echo -e "${BOLD}=================================================================${RESET}"
