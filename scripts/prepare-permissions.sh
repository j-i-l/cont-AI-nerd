#!/usr/bin/env bash
# prepare-permissions.sh — Make project directories traversable for the agent
# =========================================================================
# This script prepares project directories for use with cont-ai-nerd by:
#
#   1. Making directories traversable (g+rxs) so the agent can navigate
#   2. Setting .git/ directories to read-only for the ai group
#   3. Optionally locking sensitive files/dirs (with --lock-sensitive)
#
# The script does NOT modify individual file permissions. You control what
# the agent can read/write by setting permissions yourself:
#
#   Agent read+write : chgrp ai file && chmod g+rw file
#   Agent read-only  : chgrp ai file && chmod g+r,g-w file
#   Agent blocked    : leave group as non-ai, or chmod g= file
#
# Usage:
#   sudo ./prepare-permissions.sh [OPTIONS] <directory> [<directory>...]
#   sudo ./prepare-permissions.sh --from-config
#
# Examples:
#   sudo ./prepare-permissions.sh ~/Projects
#   sudo ./prepare-permissions.sh --dry-run ~/Projects ~/work
#   sudo ./prepare-permissions.sh --lock-sensitive ~/Projects
#   sudo ./prepare-permissions.sh --from-config
#
# =========================================================================
set -euo pipefail

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
# Files and directories matching these patterns can optionally be locked
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
LOCK_SENSITIVE=""  # "", "yes", or "no"
AGENT_GROUP="ai"
DIRECTORIES=()

# ── Usage ────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] <directory> [<directory>...]
       $(basename "$0") --from-config

Make project directories traversable for the cont-ai-nerd agent.

This script sets directories to g+rxs (traversable with setgid) and .git/
to read-only. It does NOT modify individual file permissions — you control
what the agent can access by setting file permissions yourself.

Options:
  --dry-run           Show what would be changed without making changes
  --verbose, -v       Show detailed output
  --group <name>      Specify the agent group (default: ai)
  --from-config       Read project paths from ~/.config/cont-ai-nerd/config.json
  --lock-sensitive    Lock sensitive files (600) and dirs (700) without prompting
  --no-lock-sensitive Skip sensitive file handling without prompting
  --help, -h          Show this help message

Examples:
  sudo ./prepare-permissions.sh ~/Projects
  sudo ./prepare-permissions.sh --dry-run ~/Projects ~/work
  sudo ./prepare-permissions.sh --lock-sensitive ~/Projects
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
    --lock-sensitive)
      LOCK_SENSITIVE="yes"
      shift
      ;;
    --no-lock-sensitive)
      LOCK_SENSITIVE="no"
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
STATS_GIT_READONLY=0
STATS_DIRS_TRAVERSABLE=0
STATS_DIRS_SKIPPED=0
STATS_SENSITIVE_LOCKED=0
STATS_SENSITIVE_FOUND=0

# ── Arrays to collect sensitive items ────────────────────────────────────
SENSITIVE_FILES=()
SENSITIVE_DIRS=()

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

# ── Helper: Run or print command ─────────────────────────────────────────
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${CYAN}[DRY-RUN]${RESET} $*"
  else
    debug "Running: $*"
    "$@"
  fi
}

# ── Collect sensitive items from a directory tree ────────────────────────
collect_sensitive() {
  local root="$1"
  
  # Collect sensitive directories
  while IFS= read -r -d '' dir; do
    if is_sensitive_dir "$dir"; then
      SENSITIVE_DIRS+=("$dir")
    fi
  done < <(find "$root" -type d -print0 2>/dev/null || true)
  
  # Collect sensitive files (not inside sensitive dirs)
  while IFS= read -r -d '' file; do
    if is_sensitive_file "$file"; then
      # Check if inside a sensitive directory (will be locked with parent)
      local inside_sensitive=false
      for pattern in "${SENSITIVE_DIR_PATTERNS[@]}"; do
        if [[ "$file" == *"/${pattern}/"* ]]; then
          inside_sensitive=true
          break
        fi
      done
      if [[ "$inside_sensitive" == "false" ]]; then
        SENSITIVE_FILES+=("$file")
      fi
    fi
  done < <(find "$root" -type f -print0 2>/dev/null || true)
}

# ── Lock sensitive items ─────────────────────────────────────────────────
lock_sensitive_items() {
  for dir in "${SENSITIVE_DIRS[@]}"; do
    debug "  Locking dir (700): $dir"
    run_cmd chmod 700 "$dir"
    STATS_SENSITIVE_LOCKED=$((STATS_SENSITIVE_LOCKED + 1))
  done
  
  for file in "${SENSITIVE_FILES[@]}"; do
    debug "  Locking file (600): $file"
    run_cmd chmod 600 "$file"
    STATS_SENSITIVE_LOCKED=$((STATS_SENSITIVE_LOCKED + 1))
  done
}

# ── Process a single directory tree ──────────────────────────────────────
process_directory() {
  local root="$1"
  
  info "Processing: ${root}"
  
  # Phase 1: Set .git/ directories to read-only for group
  info "  Setting .git/ to read-only..."
  while IFS= read -r -d '' gitdir; do
    debug "    Setting .git read-only: $gitdir"
    # g=rX means: group read, execute only on directories (not files)
    run_cmd chmod -R g=rX "$gitdir"
    # Also ensure no group write
    run_cmd chmod -R g-w "$gitdir"
    STATS_GIT_READONLY=$((STATS_GIT_READONLY + 1))
  done < <(find "$root" -type d -name ".git" -print0 2>/dev/null || true)
  
  # Phase 2: Set directories to g+rxs (excluding .git and sensitive)
  info "  Making directories traversable (g+rxs)..."
  while IFS= read -r -d '' dir; do
    # Skip .git directories and their contents
    if [[ "$dir" == *"/.git"* ]] || [[ "$dir" == *"/.git" ]]; then
      continue
    fi
    
    # Skip sensitive directories
    if is_sensitive_dir "$dir"; then
      debug "    Skipping sensitive dir: $dir"
      continue
    fi
    
    # Check if inside a sensitive parent
    local skip=false
    for pattern in "${SENSITIVE_DIR_PATTERNS[@]}"; do
      if [[ "$dir" == *"/${pattern}/"* ]] || [[ "$dir" == *"/${pattern}" ]]; then
        skip=true
        break
      fi
    done
    if [[ "$skip" == "true" ]]; then
      debug "    Skipping (inside sensitive parent): $dir"
      continue
    fi
    
    # Check if group is already the agent group
    local current_group
    current_group=$(stat -c '%G' "$dir")
    if [[ "$current_group" == "$AGENT_GROUP" ]]; then
      debug "    Skipping (group already ${AGENT_GROUP}): $dir"
      STATS_DIRS_SKIPPED=$((STATS_DIRS_SKIPPED + 1))
      continue
    fi
    
    debug "    Setting dir g+rxs: $dir"
    run_cmd chgrp "$AGENT_GROUP" "$dir"
    run_cmd chmod g+rxs "$dir"
    STATS_DIRS_TRAVERSABLE=$((STATS_DIRS_TRAVERSABLE + 1))
  done < <(find "$root" -type d -print0 2>/dev/null || true)
}

# ── Prompt for sensitive file handling ───────────────────────────────────
prompt_sensitive() {
  local total=${#SENSITIVE_FILES[@]}
  total=$((total + ${#SENSITIVE_DIRS[@]}))
  
  if [[ $total -eq 0 ]]; then
    return
  fi
  
  STATS_SENSITIVE_FOUND=$total
  
  echo ""
  echo -e "${YELLOW}Found ${total} sensitive file(s)/dir(s):${RESET}"
  
  # Show up to 10 items
  local count=0
  for dir in "${SENSITIVE_DIRS[@]}"; do
    if [[ $count -ge 10 ]]; then
      echo "  ... and $((total - count)) more"
      break
    fi
    local perms
    perms=$(stat -c '%a' "$dir" 2>/dev/null || echo "???")
    echo -e "  ${DIM}[dir  $perms]${RESET} $dir"
    count=$((count + 1))
  done
  for file in "${SENSITIVE_FILES[@]}"; do
    if [[ $count -ge 10 ]]; then
      echo "  ... and $((total - count)) more"
      break
    fi
    local perms
    perms=$(stat -c '%a' "$file" 2>/dev/null || echo "???")
    echo -e "  ${DIM}[file $perms]${RESET} $file"
    count=$((count + 1))
  done
  
  echo ""
  echo "Lock these from the agent? (files -> 600, dirs -> 700)"
  echo "  [1] Yes, lock all"
  echo "  [2] No, leave permissions unchanged"
  echo ""
  
  local choice
  read -r -p "Choice [2]: " choice
  choice="${choice:-2}"
  
  case "$choice" in
    1)
      info "Locking sensitive files and directories..."
      lock_sensitive_items
      ;;
    *)
      info "Leaving sensitive file permissions unchanged."
      ;;
  esac
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

# First pass: collect sensitive items from all directories
for dir in "${DIRECTORIES[@]}"; do
  collect_sensitive "$dir"
done

# Process directories (traversability + .git readonly)
for dir in "${DIRECTORIES[@]}"; do
  process_directory "$dir"
  echo ""
done

# Handle sensitive items based on flags or prompt
TOTAL_SENSITIVE=$((${#SENSITIVE_FILES[@]} + ${#SENSITIVE_DIRS[@]}))

if [[ $TOTAL_SENSITIVE -gt 0 ]]; then
  STATS_SENSITIVE_FOUND=$TOTAL_SENSITIVE
  
  if [[ "$LOCK_SENSITIVE" == "yes" ]]; then
    info "Locking ${TOTAL_SENSITIVE} sensitive file(s)/dir(s) (--lock-sensitive)..."
    lock_sensitive_items
  elif [[ "$LOCK_SENSITIVE" == "no" ]]; then
    info "Skipping ${TOTAL_SENSITIVE} sensitive file(s)/dir(s) (--no-lock-sensitive)."
  elif [[ -t 0 ]]; then
    # Interactive terminal — prompt user
    prompt_sensitive
  else
    # Non-interactive (piped/CI) — default to no locking
    info "Skipping ${TOTAL_SENSITIVE} sensitive file(s)/dir(s) (non-interactive mode)."
  fi
fi

echo -e "${BOLD}=================================================================${RESET}"
echo -e "${GREEN}  Permission preparation complete!${RESET}"
echo -e "${BOLD}=================================================================${RESET}"
echo ""
echo "  Statistics:"
echo "    .git/ dirs set read-only          : ${STATS_GIT_READONLY}"
echo "    Directories made traversable      : ${STATS_DIRS_TRAVERSABLE}"
echo "    Directories skipped (already ai)  : ${STATS_DIRS_SKIPPED}"
if [[ $STATS_SENSITIVE_FOUND -gt 0 ]]; then
  echo "    Sensitive items found             : ${STATS_SENSITIVE_FOUND}"
  echo "    Sensitive items locked            : ${STATS_SENSITIVE_LOCKED}"
fi
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  Run without --dry-run to apply these changes."
  echo ""
fi

echo -e "${BOLD}=================================================================${RESET}"
