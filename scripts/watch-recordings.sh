#!/bin/bash
# watch-recordings.sh
# Watches /recordings/ for completed Jibri recordings and auto-uploads to ArvanCloud
# Designed to run inside a Docker container

set -euo pipefail

RECORDINGS_DIR="/recordings"
STATE_DIR="/state"
UPLOAD_SCRIPT="/usr/local/bin/arvancloud-upload.sh"
INTERVAL="${WATCH_INTERVAL:-60}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

process_recordings() {
  for dir in "$RECORDINGS_DIR"/*/; do
    [ -d "$dir" ] || continue
    uuid=$(basename "$dir")

    # Skip if already uploaded
    [ -f "$STATE_DIR/$uuid" ] && continue

    # Check recording is complete (has both metadata.json + mp4)
    [ -f "$dir/metadata.json" ] || continue
    ls "$dir"/*.mp4 &>/dev/null || continue

    log "Found recording: $uuid"
    if bash "$UPLOAD_SCRIPT" "$uuid"; then
      log "Uploaded: $uuid"
    else
      log "FAILED: $uuid"
    fi
  done
}

log "Watching $RECORDINGS_DIR every ${INTERVAL}s..."
while true; do
  process_recordings
  sleep "$INTERVAL"
done
