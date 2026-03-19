#!/usr/bin/env bash
# =============================================================================
# 02-migrate-to-sharepoint.sh
#
# Migrates your local WorkDocs folder to Oracle OneDrive for Business by
# rsyncing into the locally-mounted OneDrive folder. The OneDrive sync
# client handles the upload to SharePoint automatically — no rclone or
# OAuth needed.
#
# Prerequisites:
#   - Microsoft OneDrive app running on your Mac (already confirmed working)
#   - ~/WorkDocs populated and ready (run 01-create-workdocs-structure.sh first)
#
# Usage:
#   chmod +x 02-migrate-to-sharepoint.sh
#   ./02-migrate-to-sharepoint.sh            # dry run — shows what would happen
#   ./02-migrate-to-sharepoint.sh --go       # live run — copies files
#   ./02-migrate-to-sharepoint.sh --go --delete-local   # copy + remove ~/WorkDocs after verify
#
# What this script does:
#   - Auto-detects your OneDrive-OracleCorporation mount under ~/Library/CloudStorage
#   - rsyncs ~/WorkDocs → <OneDrive-mount>/WorkDocs
#   - Preserves full directory hierarchy and skips already-synced files
#   - Writes a timestamped log to ~/WorkDocs-migration-<timestamp>.log
#   - Verifies file counts before optionally removing the local copy
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LOCAL_SOURCE="${HOME}/WorkDocs"
DEST_FOLDER="WorkDocs"                # folder name created inside OneDrive root
LOG_FILE="${HOME}/WorkDocs-migration-$(date +%Y%m%d-%H%M%S).log"
CLOUDSTG="${HOME}/Library/CloudStorage"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=true
DELETE_LOCAL=false

for arg in "$@"; do
  case "$arg" in
    --go|-go)            DRY_RUN=false ;;
    --delete-local|-delete-local)  DELETE_LOCAL=true ;;
    --help|-help|-h)
      sed -n '2,32p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Auto-detect the primary OneDrive-OracleCorporation mount
# Prefers the path WITHOUT a trailing "(2)" suffix — that's the active mount.
# ---------------------------------------------------------------------------
detect_onedrive() {
  local candidate
  # Look for an exact match first (no suffix), then fall back to any match
  candidate=$(find "$CLOUDSTG" -maxdepth 1 -type d \
    -name "OneDrive-OracleCorporation" 2>/dev/null | head -1)

  if [[ -z "$candidate" ]]; then
    # Fallback: accept any OneDrive-OracleCorporation* variant
    candidate=$(find "$CLOUDSTG" -maxdepth 1 -type d \
      -name "OneDrive-OracleCorporation*" 2>/dev/null | grep -v '(2)' | head -1)
  fi

  echo "$candidate"
}

ONEDRIVE_ROOT=$(detect_onedrive)

if [[ -z "$ONEDRIVE_ROOT" ]]; then
  echo ""
  echo "  ✗  Could not find OneDrive-OracleCorporation under ~/Library/CloudStorage"
  echo "     Make sure the OneDrive app is running and signed in to your Oracle account."
  echo "     Run:  ls ~/Library/CloudStorage/  to inspect what's mounted."
  echo ""
  exit 1
fi

DESTINATION="${ONEDRIVE_ROOT}/${DEST_FOLDER}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [[ ! -d "$LOCAL_SOURCE" ]]; then
  echo ""
  echo "  ✗  Local source not found: $LOCAL_SOURCE"
  echo "     Run 01-create-workdocs-structure.sh first, then populate it."
  echo ""
  exit 1
fi

# ---------------------------------------------------------------------------
# Build rsync flags
#   -a  archive mode (recursive, preserves timestamps, permissions, symlinks)
#   -v  verbose
#   -h  human-readable sizes
#   --progress  per-file transfer progress
#   --exclude   skip macOS noise files that don't belong on OneDrive
# ---------------------------------------------------------------------------
RSYNC_FLAGS=(
  -a
  -v
  -h
  --progress
  --exclude=".DS_Store"
  --exclude="._*"
  --exclude=".Spotlight-V100"
  --exclude=".Trashes"
  --log-file="$LOG_FILE"
)

if $DRY_RUN; then
  RSYNC_FLAGS+=(--dry-run)
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  WorkDocs → SharePoint Migration"
if $DRY_RUN; then
  echo "  MODE: *** DRY RUN — NO FILES WILL BE COPIED ***"
  echo "  Pass --go or -go to run for real"
else
  echo "  MODE: *** LIVE RUN — FILES WILL BE COPIED ***"
fi
echo ""
echo "  From : $LOCAL_SOURCE"
echo "  To   : $DESTINATION"
echo "  Log  : $LOG_FILE"
echo ""
echo "  OneDrive will sync to SharePoint in the background."
echo "  Monitor status via the OneDrive menu-bar icon."
echo "═══════════════════════════════════════════════════════"
echo ""

# ---------------------------------------------------------------------------
# Run the sync
# Note: trailing slash on source copies CONTENTS into destination folder,
# not the folder itself — resulting in OneDrive/WorkDocs/<your files>
# ---------------------------------------------------------------------------
mkdir -p "$DESTINATION"
rsync "${RSYNC_FLAGS[@]}" "${LOCAL_SOURCE}/" "${DESTINATION}/"

EXIT_CODE=$?

# ---------------------------------------------------------------------------
# Post-run summary
# ---------------------------------------------------------------------------
echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  if $DRY_RUN; then
    echo "  ✓  Dry run complete — no files were copied."
    echo "     Review the output above, then run with --go when ready."
  else
    echo "  ✓  rsync finished successfully."
    echo "  Log written to: $LOG_FILE"
    echo ""
    echo "  OneDrive will now sync $DESTINATION to SharePoint."
    echo "  Watch the menu-bar icon — it shows a spinning icon while syncing."

    if $DELETE_LOCAL; then
      echo ""
      echo "  → --delete-local requested. Verifying before removing local copy..."

      LOCAL_COUNT=$(find "$LOCAL_SOURCE" -type f | wc -l | tr -d ' ')
      DEST_COUNT=$(find "$DESTINATION" -type f | wc -l | tr -d ' ')

      echo "  Local files      : $LOCAL_COUNT"
      echo "  OneDrive files   : $DEST_COUNT"

      if [[ "$LOCAL_COUNT" -eq "$DEST_COUNT" ]]; then
        echo "  ✓  Counts match. Removing local copy: $LOCAL_SOURCE"
        rm -rf "$LOCAL_SOURCE"
        echo "  ✓  Local copy removed."
        echo ""
        echo "  ⚠  Wait for the OneDrive menu-bar icon to finish syncing"
        echo "     before closing your laptop — files are uploading."
      else
        echo ""
        echo "  ⚠  File counts differ — NOT deleting local copy."
        echo "     This may be normal if OneDrive hasn't finished syncing yet."
        echo "     Re-run with --delete-local after OneDrive finishes uploading."
      fi
    fi
  fi
else
  echo "  ✗  rsync exited with code $EXIT_CODE — check log for errors:"
  echo "     $LOG_FILE"
fi

echo ""
echo "  Tip: verify your files at https://oracle-my.sharepoint.com/my"
echo ""
