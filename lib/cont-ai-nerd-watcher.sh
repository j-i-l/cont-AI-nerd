#!/usr/bin/env bash
# cont-ai-nerd-watcher.sh
# ---------------------------------------------------------------------------
# Inotify-based daemon that reassigns ownership of files created by the agent
# user back to the primary (human) user while preserving group-write access
# so the agent retains read/write through the 'ai' group.
#
# Usage: cont-ai-nerd-watcher.sh <primary_user> <agent_user> <dir> [<dir>...]
# ---------------------------------------------------------------------------
set -euo pipefail

PRIMARY_USER="${1:?Usage: $0 <primary_user> <agent_user> <dir> [<dir>...]}"
AGENT_USER="${2:?Usage: $0 <primary_user> <agent_user> <dir> [<dir>...]}"
shift 2

WATCH_DIRS=("$@")
if [[ ${#WATCH_DIRS[@]} -eq 0 ]]; then
  echo "Error: at least one watch directory is required." >&2
  exit 1
fi

PRIMARY_UID=$(id -u "$PRIMARY_USER")
AGENT_UID=$(id -u "$AGENT_USER")
AI_GID=$(getent group ai | cut -d: -f3)

echo "cont-ai-nerd watcher starting: primary=${PRIMARY_USER}(${PRIMARY_UID}) agent=${AGENT_USER}(${AGENT_UID}) gid=ai(${AI_GID})"
echo "Watching: ${WATCH_DIRS[*]}"

# Monitor for file creation and moves (which look like creates to the target).
# --recursive watches subdirectories as they appear.
inotifywait -m -r \
  -e create \
  -e moved_to \
  --format '%w%f' \
  "${WATCH_DIRS[@]}" | \
while IFS= read -r filepath; do
  # Guard: the path may have been deleted between event and processing.
  [[ -e "$filepath" ]] || continue

  file_uid=$(stat -c '%u' "$filepath" 2>/dev/null) || continue

  if [[ "$file_uid" == "$AGENT_UID" ]]; then
    chown "${PRIMARY_UID}:${AI_GID}" "$filepath" 2>/dev/null || true
    # Preserve group-write so the agent can still modify through 'ai' group.
    chmod g+w "$filepath" 2>/dev/null || true

    # If a new directory was created, propagate the setgid bit so that
    # further files created inside it also inherit the 'ai' group.
    if [[ -d "$filepath" ]]; then
      chmod g+s "$filepath" 2>/dev/null || true
    fi
  fi
done
