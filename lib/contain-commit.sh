#!/usr/bin/env bash
# contain-commit.sh
# ---------------------------------------------------------------------------
# Snapshots the running contain container's writable layer into a new
# tagged image.  Old tags are pruned to keep disk usage bounded.
#
# Intended to be called by a systemd timer (see contain-commit.timer).
# ---------------------------------------------------------------------------
set -euo pipefail

CONTAINER_NAME="contAIn"
IMAGE_NAME="localhost/contAIn"
KEEP_TAGS=5

# Nothing to do if the container is not running.
if ! podman inspect --type container "$CONTAINER_NAME" &>/dev/null; then
  echo "Container ${CONTAINER_NAME} not found — skipping commit."
  exit 0
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "Committing ${CONTAINER_NAME} -> ${IMAGE_NAME}:${TIMESTAMP} ..."
podman commit "$CONTAINER_NAME" "${IMAGE_NAME}:${TIMESTAMP}"
podman tag "${IMAGE_NAME}:${TIMESTAMP}" "${IMAGE_NAME}:latest"

echo "Pruning old tags (keeping ${KEEP_TAGS} most recent)..."
# List date-stamped tags, newest first, drop the first KEEP_TAGS, remove rest.
podman images --format '{{.Tag}} {{.ID}}' "$IMAGE_NAME" | \
  grep -E '^[0-9]{8}-[0-9]{6}' | \
  sort -r | \
  tail -n +"$(( KEEP_TAGS + 1 ))" | \
  awk '{print $2}' | \
  xargs -r podman rmi 2>/dev/null || true

echo "Done.  Current images:"
podman images "$IMAGE_NAME"
