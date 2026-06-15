#!/bin/bash
# arvancloud-upload.sh <session-uuid>
# Uploads a Jibri recording directory to ArvanCloud VOD
# Uses: ARVAN_API_KEY, ARVAN_CHANNEL_ID from environment

set -euo pipefail

UUID="${1:-}"
RECORDINGS_DIR="/recordings"
STATE_DIR="/state"

[ -z "$UUID" ] && echo "Usage: $0 <session-uuid>" && exit 1

SESSION_DIR="$RECORDINGS_DIR/$UUID"
METADATA="$SESSION_DIR/metadata.json"
MARKER="$STATE_DIR/$UUID"

# Skip if already uploaded
if [ -f "$MARKER" ]; then
  exit 0
fi

# Find the mp4
shopt -s nullglob
MP4_FILES=("$SESSION_DIR"/*.mp4)
shopt -u nullglob
MP4_FILE="${MP4_FILES[0]:-}"

# Validate
if [ ! -f "$METADATA" ] || [ -z "$MP4_FILE" ]; then
  exit 1
fi

# Config
AUTH="Authorization: ${ARVAN_API_KEY}"
BASE="${ARVAN_VOD_BASE_URL:-https://napi.arvancloud.ir/vod/2.0}"
CHANNEL_ID="${ARVAN_CHANNEL_ID}"

# Validate API key and channel
if [ -z "${ARVAN_API_KEY:-}" ] || [ -z "$CHANNEL_ID" ]; then
  echo "[FAIL] $UUID — ARVAN_API_KEY or ARVAN_CHANNEL_ID not set"
  exit 1
fi

# Extract metadata
ROOM=$(jq -r '.meeting_url // empty' "$METADATA" | sed 's|.*/||')
TIMESTAMP=$(date -d "@$(stat -c %Y "$MP4_FILE")" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || date '+%Y/%m/%d %H:%M:%S')
[ -z "$ROOM" ] && ROOM="unknown"
TITLE="$ROOM $TIMESTAMP"

FILESIZE=$(stat -c %s "$MP4_FILE")
FILENAME=$(basename "$MP4_FILE")
FILENAME_B64=$(echo -n "$FILENAME" | base64 -w0)
FILETYPE_B64=$(echo -n "video/mp4" | base64 -w0)

echo "[UPLOAD] $UUID → $TITLE ($FILESIZE bytes)"

# Step 1: Initiate tus upload
LOCATION=$(curl -s -D - \
  -X POST "$BASE/channels/$CHANNEL_ID/files" \
  -H "$AUTH" \
  -H "tus-resumable: 1.0.0" \
  -H "upload-length: $FILESIZE" \
  -H "upload-metadata: filename $FILENAME_B64,filetype $FILETYPE_B64" \
  2>/dev/null | grep -i "^location:" | awk '{print $2}' | tr -d '\r\n')

if [ -z "$LOCATION" ]; then
  echo "[FAIL] $UUID — tus initiation failed"
  exit 1
fi

FILE_ID=$(echo "$LOCATION" | awk -F/ '{print $NF}')

# Step 2: Upload file bytes (tus PATCH)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PATCH "$LOCATION" \
  -H "$AUTH" \
  -H "tus-resumable: 1.0.0" \
  -H "upload-offset: 0" \
  -H "Content-Type: application/offset+octet-stream" \
  --data-binary "@$MP4_FILE" \
  2>/dev/null)

if [ "$HTTP_CODE" != "204" ]; then
  echo "[FAIL] $UUID — tus upload failed (HTTP $HTTP_CODE)"
  exit 1
fi

# Step 3: Create video entry
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE/channels/$CHANNEL_ID/videos" \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -d "{\"title\":\"$TITLE\",\"file_id\":\"$FILE_ID\",\"convert_mode\":\"auto\"}" \
  2>/dev/null)

if [ "$HTTP_CODE" != "201" ]; then
  echo "[FAIL] $UUID — video creation failed (HTTP $HTTP_CODE)"
  exit 1
fi

echo "$(date -u +%FT%TZ)" > "$MARKER"
echo "[DONE] $UUID — $TITLE uploaded successfully"
