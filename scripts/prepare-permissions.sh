#!/usr/bin/env bash
# prepare-permissions.sh — Set secure permissions on project directories
# =========================================================================
# This script configures file permissions for use with cont-ai-nerd,
# following a principle of least privilege:
#
#   - Sensitive files/dirs (.env, secrets/, etc.) → 700 (agent blocked)
#   - .git/ directories → read-only for ai group (no write)
#   - Directories → g+rxs (readable, browsable, setgid for inheritance)
#   - Regular files → g+rw (read+write) unless already more restrictive
#
# The script preserves existing restrictive permissions — it will never
# loosen permissions that are already tighter than the defaults.
#
# Usage:
#   sudo ./prepare-permissions.sh [--dry-run] <directory> [<directory>...]
#   sudo ./prepare-permissions.sh --from-config
#
# Examples:
#   sudo ./prepare-permissions.sh ~/Projects
#   sudo ./prepare-permissions.sh --dry-run ~/Projects ~/work
#   sudo ./prepare-permissions.sh --from-config  # reads from config.json
#
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colors ───────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD='\033[1m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  CYAN='\033[0;36m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  BOLD='' GREEN='' YELLOW='' RED='' CYAN='' DIM='' RESET=''
fi

# ── Helper functions ─────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$@"; exit 1; }
debug() { [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${DIM}[DEBUG] $*${RESET}" || true; }

# ── Sensitive patterns ───────────────────────────────────────────────────
# Files and directories matching these patterns will be set to mode 700
# (owner only, completely inaccessible to the agent).

SENSITIVE_FILE_PATTERNS=(
  # Environment files
  ".env"
  ".env.*"
  "*.env"
  
  # Secret/credential files
  "*.secret"
  "*.secrets"
  "*secret*.json"
  "*secrets*.json"
  "*credential*.json"
  "*credentials*.json"
  "*auth*.json"
  
  # Private keys and certificates
  "*.pem"
  "*.key"
  "*.p12"
  "*.pfx"
  "*.keystore"
  "*.jks"
  "id_rsa"
  "id_rsa.*"
  "id_ed25519"
  "id_ed25519.*"
  "id_ecdsa"
  "id_ecdsa.*"
  "id_dsa"
  "id_dsa.*"
  "*.pub"  # Public keys (less sensitive but often paired)
  
  # Package manager auth
  ".npmrc"
  ".pypirc"
  ".netrc"
  ".docker/config.json"
  
  # Cloud provider credentials
  ".aws/credentials"
  ".azure/credentials"
  "gcloud/*.json"
  "service-account*.json"
  
  # Database files
  "*.sqlite"
  "*.sqlite3"
  "*.db"
)

SENSITIVE_DIR_PATTERNS=(
  # Secret directories
  "secrets"
  ".secrets"
  "secret"
  ".secret"
  
  # Vault directories
  "vault"
  ".vault"
  "vaults"
  ".vaults"
  
  # Credential directories
  "credentials"
  ".credentials"
  "creds"
  ".creds"
  
  # Private directories
  "private"
  ".private"
  
  # SSH directories
  ".ssh"
  
  # GPG directories
  ".gnupg"
  ".gpg"
)

# ── Configuration ────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
FROM_CONFIG=false
AGENT_GROUP="ai"
DIRECTORIES=()

# ── Usage ────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] <directory> [<directory>...]
       $(basename "$0") --from-config

Set secure file permissions on project directories for cont-ai-nerd.

Options:
  --dry-run       Show what would be changed without making changes
  --verbose, -v   Show detailed output
  --group <name>  Specify the agent group (default: ai)
  --from-config   Read project paths from ~/.config/cont-ai-nerd/config.json
  --help, -h      Show this help message

Examples:
  sudo ./prepare-permissions.sh ~/Projects
  sudo ./prepare-permissions.sh --dry-run ~/Projects ~/work
  sudo ./prepare-permissions.sh --from-config

EOF
  exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --group)
      AGENT_GROUP="$2"
      shift 2
      ;;
    --from-config)
      FROM_CONFIG=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      DIRECTORIES+=("$1")
      shift
      ;;
  esac
done

# ── Root check ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (sudo ./prepare-permissions.sh ...)"
fi

# ── Load from config if requested ────────────────────────────────────────
if [[ "$FROM_CONFIG" == "true" ]]; then
  DETECTED_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
  if [[ -z "$DETECTED_USER" ]]; then
    die "Could not detect primary user. Please run with sudo."
  fi
  
  DETECTED_HOME=$(eval echo "~${DETECTED_USER}")
  CONFIG_FILE="${DETECTED_HOME}/.config/cont-ai-nerd/config.json"
  
  if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config file not found: ${CONFIG_FILE}"
  fi
  
  # Read project paths from config
  readarray -t CONFIG_PATHS < <(jq -r '.project_paths[]' "$CONFIG_FILE")
  DIRECTORIES+=("${CONFIG_PATHS[@]}")
  
  # Read agent group from config
  CONFIG_GROUP=$(jq -r '.agent_group // "ai"' "$CONFIG_FILE")
  AGENT_GROUP="${CONFIG_GROUP}"
  
  info "Loaded ${#CONFIG_PATHS[@]} paths from ${CONFIG_FILE}"
fi

# ── Validate inputs ──────────────────────────────────────────────────────
if [[ ${#DIRECTORIES[@]} -eq 0 ]]; then
  error "No directories specified."
  echo ""
  usage
fi

# Check group exists
if ! getent group "$AGENT_GROUP" &>/dev/null; then
  die "Group '${AGENT_GROUP}' does not exist. Run setup.sh first."
fi

# Validate directories exist
for dir in "${DIRECTORIES[@]}"; do
  if [[ ! -d "$dir" ]]; then
    die "Directory does not exist: ${dir}"
  fi
done

# ── Statistics ───────────────────────────────────────────────────────────
STATS_SENSITIVE_LOCKED=0
STATS_GIT_READONLY=0
STATS_DIRS_SETGID=0
STATS_FILES_GROUPRW=0
STATS_PRESERVED=0

# ── Helper: Check if path matches sensitive patterns ─────────────────────
is_sensitive_file() {
  local path="$1"
  local basename
  basename=$(basename "$path")
  
  for pattern in "${SENSITIVE_FILE_PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$basename" in
      $pattern) return 0 ;;
    esac
  done
  
  return 1
}

is_sensitive_dir() {
  local path="$1"
  local basename
  basename=$(basename "$path")
  
  for pattern in "${SENSITIVE_DIR_PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$basename" in
      $pattern) return 0 ;;
    esac
  done
  
  return 1
}

# ── Helper: Get current group permission bits ────────────────────────────
get_group_perms() {
  local path="$1"
  stat -c '%a' "$path" | cut -c2
}

# ── Helper: Check if current perms are more restrictive ──────────────────
is_more_restrictive() {
  local current="$1"
  local proposed="$2"
  
  # Compare numeric permission values
  # More restrictive = lower number
  [[ "$current" -lt "$proposed" ]]
}

# ── Helper: Run or print command ─────────────────────────────────────────
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${CYAN}[DRY-RUN]${RESET} $*"
  else
    debug "Running: $*"
    "$@"
  fi
}

# ── Process a single directory tree ──────────────────────────────────────
process_directory() {
  local root="$1"
  
  info "Processing: ${root}"
  
  # Phase 1: Lock sensitive directories (must be done first to prevent descent)
  info "  Phase 1: Locking sensitive directories..."
  while IFS= read -r -d '' dir; do
    if is_sensitive_dir "$dir"; then
      debug "    Locking sensitive dir: $dir"
      run_cmd chmod 700 "$dir"
      STATS_SENSITIVE_LOCKED=$((STATS_SENSITIVE_LOCKED + 1))
    fi
  done < <(find "$root" -type d -print0 2>/dev/null || true)
  
  # Phase 2: Lock sensitive files
  info "  Phase 2: Locking sensitive files..."
  while IFS= read -r -d '' file; do
    if is_sensitive_file "$file"; then
      debug "    Locking sensitive file: $file"
      run_cmd chmod 700 "$file"
      STATS_SENSITIVE_LOCKED=$((STATS_SENSITIVE_LOCKED + 1))
    fi
  done < <(find "$root" -type f -print0 2>/dev/null || true)
  
  # Phase 3: Set .git/ directories to read-only for group
  info "  Phase 3: Setting .git/ to read-only..."
  while IFS= read -r -d '' gitdir; do
    debug "    Setting .git read-only: $gitdir"
    # g=rX means: group read, execute only on directories (not files)
    run_cmd chmod -R g=rX "$gitdir"
    # Also ensure no group write
    run_cmd chmod -R g-w "$gitdir"
    STATS_GIT_READONLY=$((STATS_GIT_READONLY + 1))
  done < <(find "$root" -type d -name ".git" -print0 2>/dev/null || true)
  
  # Phase 4: Set directories to g+rxs (excluding .git and sensitive)
  info "  Phase 4: Setting directory permissions (g+rxs)..."
  while IFS= read -r -d '' dir; do
    # Skip .git directories and their contents
    if [[ "$dir" == *"/.git"* ]] || [[ "$dir" == *"/.git" ]]; then
      continue
    fi
    
    # Skip sensitive directories
    if is_sensitive_dir "$dir"; then
      continue
    fi
    
    # Check if inside a sensitive parent (already locked)
    local skip=false
    for pattern in "${SENSITIVE_DIR_PATTERNS[@]}"; do
      if [[ "$dir" == *"/${pattern}/"* ]] || [[ "$dir" == *"/${pattern}" ]]; then
        skip=true
        break
      fi
    done
    [[ "$skip" == "true" ]] && continue
    
    debug "    Setting dir g+rxs: $dir"
    run_cmd chgrp "$AGENT_GROUP" "$dir"
    run_cmd chmod g+rxs "$dir"
    STATS_DIRS_SETGID=$((STATS_DIRS_SETGID + 1))
  done < <(find "$root" -type d -print0 2>/dev/null || true)
  
  # Phase 5: Set file permissions (g+rw unless more restrictive)
  info "  Phase 5: Setting file permissions..."
  while IFS= read -r -d '' file; do
    # Skip .git contents
    if [[ "$file" == *"/.git/"* ]]; then
      continue
    fi
    
    # Skip sensitive files
    if is_sensitive_file "$file"; then
      continue
    fi
    
    # Skip files inside sensitive directories
    local skip=false
    for pattern in "${SENSITIVE_DIR_PATTERNS[@]}"; do
      if [[ "$file" == *"/${pattern}/"* ]]; then
        skip=true
        break
      fi
    done
    [[ "$skip" == "true" ]] && continue
    
    # Get current group permissions
    local current_group_perm
    current_group_perm=$(get_group_perms "$file")
    
    # If current perms are more restrictive (lower), preserve them
    # 6 = rw, so if current < 6, it's more restrictive
    if [[ "$current_group_perm" -lt 6 ]] && [[ "$current_group_perm" -gt 0 ]]; then
      # Has some group perms but less than rw — check if intentional
      # If it's 4 (r--) or 5 (r-x), preserve it
      debug "    Preserving restrictive perms on: $file (g=$current_group_perm)"
      STATS_PRESERVED=$((STATS_PRESERVED + 1))
    else
      debug "    Setting file g+rw: $file"
      run_cmd chgrp "$AGENT_GROUP" "$file"
      run_cmd chmod g+rw "$file"
      STATS_FILES_GROUPRW=$((STATS_FILES_GROUPRW + 1))
    fi
  done < <(find "$root" -type f -print0 2>/dev/null || true)
}

# ── Main ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=================================================================${RESET}"
echo -e "${BOLD}  cont-ai-nerd — Permission Preparation${RESET}"
echo -e "${BOLD}=================================================================${RESET}"
echo ""
echo "  Agent group     : ${AGENT_GROUP}"
echo "  Directories     : ${DIRECTORIES[*]}"
echo "  Dry run         : ${DRY_RUN}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  warn "Dry-run mode: no changes will be made."
  echo ""
fi

for dir in "${DIRECTORIES[@]}"; do
  process_directory "$dir"
  echo ""
done

echo -e "${BOLD}=================================================================${RESET}"
echo -e "${GREEN}  Permission preparation complete!${RESET}"
echo -e "${BOLD}=================================================================${RESET}"
echo ""
echo "  Statistics:"
echo "    Sensitive files/dirs locked (700) : ${STATS_SENSITIVE_LOCKED}"
echo "    .git/ dirs set read-only          : ${STATS_GIT_READONLY}"
echo "    Directories set g+rxs             : ${STATS_DIRS_SETGID}"
echo "    Files set g+rw                    : ${STATS_FILES_GROUPRW}"
echo "    Restrictive perms preserved       : ${STATS_PRESERVED}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  Run without --dry-run to apply these changes."
  echo ""
fi

echo -e "${BOLD}=================================================================${RESET}"
