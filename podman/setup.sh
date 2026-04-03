#!/usr/bin/env bash
# setup.sh — cont-ai-nerd: rootful podman deployment
# =========================================================================
# Idempotent setup script. Safe to re-run at any time to converge to the
# desired state.  Every step is a no-op when the system already matches.
#
# What it does:
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
#   sudo ./setup.sh [primary_user] [project_path ...]
#
# Arguments:
#   primary_user   Login name of the human user (default: detected via
#                  SUDO_USER / logname).
#   project_path   One or more directories to bind into the container.
#                  Defaults to /home/<primary_user>/Projects.
#
# Examples:
#   sudo ./setup.sh                          # auto-detect user, ~/Projects
#   sudo ./setup.sh jonas                    # explicit user, ~/Projects
#   sudo ./setup.sh jonas ~/work ~/oss       # explicit user, two paths
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Configuration ────────────────────────────────────────────────────────
AGENT_USER="agent"
AGENT_GROUP="ai"
INSTALL_DIR="/opt/cont-ai-nerd"
QUADLET_DIR="/etc/containers/systemd"
HOST="127.0.0.1"
PORT=3000

# ── Argument parsing ─────────────────────────────────────────────────────
PRIMARY_USER="${1:-${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}}"
shift 2>/dev/null || true

if [[ $# -gt 0 ]]; then
  PROJECT_PATHS=("$@")
else
  PROJECT_PATHS=("/home/${PRIMARY_USER}/Projects")
fi

PRIMARY_HOME=$(eval echo "~${PRIMARY_USER}")
CONTAINERD_CONFIG="${PRIMARY_HOME}/.config/cont-ai-nerd"

echo "================================================================="
echo "  cont-ai-nerd — Podman Setup"
echo "================================================================="
echo "  Primary user  : ${PRIMARY_USER} (home: ${PRIMARY_HOME})"
echo "  Agent user    : ${AGENT_USER}"
echo "  Agent group   : ${AGENT_GROUP}"
echo "  Project paths : ${PROJECT_PATHS[*]}"
echo "  Config dir    : ${CONTAINERD_CONFIG}"
echo "  Install dir   : ${INSTALL_DIR}"
echo "  Listen        : ${HOST}:${PORT}"
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
# the paths that are bind-mounted into the container.
POLICY_FILE="${CONTAINERD_CONFIG}/opencode.json"
{
  echo '{'
  echo '  "$schema": "https://opencode.ai/config.json",'
  echo '  "permission": {'
  echo '    "external_directory": {'
  for i in "${!PROJECT_PATHS[@]}"; do
    comma=$([[ $i -lt $((${#PROJECT_PATHS[@]} - 1)) ]] && echo "," || echo "")
    echo "      \"${PROJECT_PATHS[$i]}/**\": \"allow\"${comma}"
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

# ── 5. Build the container image ─────────────────────────────────────────
echo ""
echo "==> [5/8] Building container image..."

podman build \
  --build-arg "AGENT_UID=${AGENT_UID}" \
  --build-arg "AGENT_GID=${AI_GID}" \
  -t localhost/cont-ai-nerd:latest \
  -f "${SCRIPT_DIR}/Containerfile" \
  "${SCRIPT_DIR}"

echo "    Image built: localhost/cont-ai-nerd:latest"

# ── 6. Install helper scripts ─────────────────────────────────────────────
echo ""
echo "==> [6/8] Installing scripts to ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}"
install -m 755 "${SCRIPT_DIR}/cont-ai-nerd-watcher.sh"  "${INSTALL_DIR}/"
install -m 755 "${SCRIPT_DIR}/cont-ai-nerd-commit.sh"   "${INSTALL_DIR}/"

# ── 7. Render & install systemd units ─────────────────────────────────────
echo ""
echo "==> [7/8] Installing systemd units..."

# --- Quadlet ---
mkdir -p "${QUADLET_DIR}"

# Build the Volume= lines for project paths.
VOLUME_LINES=""
for p in "${PROJECT_PATHS[@]}"; do
  VOLUME_LINES+="Volume=${p}:${p}:rw,Z"$'\n'
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
  "${SCRIPT_DIR}/cont-ai-nerd.container.in" | \
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
  "${SCRIPT_DIR}/cont-ai-nerd-watcher.service.in" \
  > /etc/systemd/system/cont-ai-nerd-watcher.service

echo "    Installed cont-ai-nerd-watcher.service"

# --- Commit service ---
sed \
  -e "s|@@INSTALL_DIR@@|${INSTALL_DIR}|g" \
  "${SCRIPT_DIR}/cont-ai-nerd-commit.service" \
  > /etc/systemd/system/cont-ai-nerd-commit.service

echo "    Installed cont-ai-nerd-commit.service"

# --- Commit timer (no templating needed) ---
cp "${SCRIPT_DIR}/cont-ai-nerd-commit.timer" \
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
echo "  Container : sudo podman ps | grep cont-ai-nerd"
echo "  Watcher   : systemctl status cont-ai-nerd-watcher"
echo "  Commits   : systemctl list-timers cont-ai-nerd-commit"
echo "  Logs      : journalctl -u cont-ai-nerd -f"
echo "================================================================="
