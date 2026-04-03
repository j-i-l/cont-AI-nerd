#!/bin/sh
# opencode-tui — Attach an interactive TUI to the running cont-ai-nerd server
# ============================================================================
# This script runs inside the container and connects to the already-running
# OpenCode server instance, providing an interactive terminal UI.
#
# Usage:
#   podman exec -it cont-ai-nerd opencode-tui
#   podman exec -it cont-ai-nerd opencode-tui --session <id>
#
# The script reads HOST and PORT from the mounted config.json file.
# ============================================================================
set -eu

CONFIG="/etc/cont-ai-nerd/config.json"

if [ ! -f "$CONFIG" ]; then
  echo "Error: Config file not found at $CONFIG" >&2
  echo "Make sure config.json is mounted into the container." >&2
  exit 1
fi

HOST=$(jq -r '.host // "127.0.0.1"' "$CONFIG")
PORT=$(jq -r '.port // 3000' "$CONFIG")

if [ -z "$HOST" ] || [ "$HOST" = "null" ]; then
  HOST="127.0.0.1"
fi

if [ -z "$PORT" ] || [ "$PORT" = "null" ]; then
  PORT="3000"
fi

exec opencode attach "http://${HOST}:${PORT}" "$@"
