#!/usr/bin/env bash
# cont-ai-nerd-tui — Interactive TUI for cont-ai-nerd
# =========================================================================
# Attaches an interactive TUI to the running cont-ai-nerd container.
# All data (auth, database, model preferences) is persisted via the
# container's read-write bind mounts — no separate container needed.
#
# Authentication via /connect works directly: the server handles credential
# storage through its API and writes auth.json to the mounted data directory.
#
# Usage:
#   sudo cont-ai-nerd-tui              # Start interactive TUI
#   sudo cont-ai-nerd-tui --session X  # Resume session X
#
# =========================================================================
set -euo pipefail

# ── Check that the main container is running ─────────────────────────────
# Use systemctl is-active rather than `podman ps` because the container is
# managed as a rootful service; an unprivileged `podman ps` only sees the
# rootless namespace and would always report the container as not running.
if ! systemctl is-active --quiet cont-ai-nerd.service; then
  echo "Error: cont-ai-nerd container is not running." >&2
  echo "Start it with: systemctl start cont-ai-nerd" >&2
  exit 1
fi

# ── Attach TUI to the running container ──────────────────────────────────
exec podman exec -it cont-ai-nerd opencode-tui "$@"
