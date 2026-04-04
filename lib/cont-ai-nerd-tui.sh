#!/usr/bin/env bash
# cont-ai-nerd-tui — Interactive TUI with authentication capability
# =========================================================================
# Spawns a separate container instance that can run /connect to authenticate.
# The auth directory (~/.local/share/opencode) is mounted read-write so that
# credentials can be saved.
#
# This is different from `podman exec -it cont-ai-nerd opencode-tui` which
# runs inside the main container with read-only auth (cannot run /connect).
#
# Usage:
#   sudo cont-ai-nerd-tui              # Start interactive TUI
#   sudo cont-ai-nerd-tui --session X  # Resume session X
#
# =========================================================================
set -euo pipefail

# ── Determine the primary user's home directory ──────────────────────────
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME=$(eval echo "~${SUDO_USER}")
else
  USER_HOME="$HOME"
fi

CONFIG="${USER_HOME}/.config/cont-ai-nerd/config.json"

# ── Validate config exists ───────────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: Configuration not found at $CONFIG" >&2
  echo "Run setup.sh first to configure cont-ai-nerd." >&2
  exit 1
fi

# ── Read configuration ───────────────────────────────────────────────────
HOST=$(jq -r '.host // "127.0.0.1"' "$CONFIG")
PORT=$(jq -r '.port // 3000' "$CONFIG")
AGENT_USER=$(jq -r '.agent_user // "agent"' "$CONFIG")
AGENT_GROUP=$(jq -r '.agent_group // "ai"' "$CONFIG")

# ── Resolve UID/GID ──────────────────────────────────────────────────────
if ! AGENT_UID=$(id -u "$AGENT_USER" 2>/dev/null); then
  echo "Error: Agent user '$AGENT_USER' not found." >&2
  echo "Run setup.sh first to create the agent user." >&2
  exit 1
fi

if ! AGENT_GID=$(getent group "$AGENT_GROUP" | cut -d: -f3); then
  echo "Error: Agent group '$AGENT_GROUP' not found." >&2
  echo "Run setup.sh first to create the agent group." >&2
  exit 1
fi

# ── Check that the main container is running ─────────────────────────────
if ! podman ps --filter name=cont-ai-nerd --format '{{.Names}}' | grep -q '^cont-ai-nerd$'; then
  echo "Error: cont-ai-nerd container is not running." >&2
  echo "Start it with: systemctl start cont-ai-nerd" >&2
  exit 1
fi

# ── Launch TUI container ─────────────────────────────────────────────────
# This is a separate ephemeral container that:
#   - Mounts auth directory rw (so /connect can save credentials)
#   - Mounts config directories ro (same as main container)
#   - Connects to the running headless server via `opencode attach`
exec podman run --rm -it \
  --name cont-ai-nerd-tui-$$ \
  --user "${AGENT_UID}:${AGENT_GID}" \
  --network host \
  -v "${USER_HOME}/.local/share/opencode:/home/agent/.local/share/opencode:rw" \
  -v "${USER_HOME}/.config/opencode:/home/agent/.config/opencode:ro" \
  -v "${USER_HOME}/.config/cont-ai-nerd:/etc/cont-ai-nerd:ro" \
  --entrypoint opencode \
  localhost/cont-ai-nerd:latest \
  attach "http://${HOST}:${PORT}" "$@"
