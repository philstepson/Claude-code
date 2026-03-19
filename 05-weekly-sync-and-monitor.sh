#!/usr/bin/env bash
# =============================================================================
# 05-weekly-sync-and-monitor.sh
#
# Intended to run weekly at midnight via launchd (see com.oracle.workdocs-weeklysync.plist).
# Can also be run manually at any time.
#
# What it does on every run:
#   1. rsync ~/WorkDocs → SharePoint OneDrive mount
#   2. Check SharePoint storage usage as a percentage of quota
#   3. If usage >= QUOTA_THRESHOLD_PCT (default 90%):
#        a. tar.gz the entire WorkDocs folder from SharePoint
#        b. Upload to OCI Object Storage (workdocs-archive bucket)
#        c. Verify checksum
#        d. Delete WorkDocs content from SharePoint only after confirmed upload
#   4. Send a macOS notification summarising what happened
#
# Usage:
#   chmod +x 05-weekly-sync-and-monitor.sh
#   ./05-weekly-sync-and-monitor.sh            # dry run — no changes
#   ./05-weekly-sync-and-monitor.sh --go       # live run
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# OneDrive / SharePoint
ONEDRIVE_ROOT="$HOME/Library/CloudStorage/OneDrive-OracleCorporation"
WORKDOCS_LOCAL="$HOME/WorkDocs"
WORKDOCS_SHAREPOINT="$ONEDRIVE_ROOT/WorkDocs"

# SharePoint quota — set to your Oracle OneDrive allocation in GB
# Used as the denominator when df cannot read the virtual filesystem quota.
# Check yours at https://oracle-my.sharepoint.com/my → Settings → Storage metrics
SHAREPOINT_QUOTA_GB=1024    # adjust to your actual allocation (1TB default)

# Emergency archive threshold — trigger full evacuation above this %
QUOTA_THRESHOLD_PCT=90

# OCI — philip.stephenson / us-phoenix-1
NAMESPACE="axxduehrw7lz"
REGION="us-phoenix-1"
COMPARTMENT_OCID="ocid1.compartment.oc1..aaaaaaaa4gxfntpkf65wzzoddjuak6fk4emk6fj2t2pmf6bpglotjjhk436a"
BUCKET="workdocs-archive"

# Staging area for compression
ARCHIVE_TMP="${TMPDIR:-/tmp}/workdocs-weekly-staging"

# Log file — kept in ~/Library/Logs so launchd can write there too
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/workdocs-weekly-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=true

for arg in "$@"; do
  case "$arg" in
    --go|-go) DRY_RUN=false ;;
    --help|-help|-h)
      grep '^#' "$0" | head -30 | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging — stdout + file
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

log() {
  local msg="[$(date '+%Y/%m/%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

notify() {
  # macOS notification — visible even when script ran at midnight
  osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  local fail=false

  command -v rsync &>/dev/null   || { log "✗ rsync not found"; fail=true; }
  command -v oci   &>/dev/null   || { log "✗ OCI CLI not found"; fail=true; }

  [[ -d "$WORKDOCS_LOCAL" ]]      || { log "✗ ~/WorkDocs not found — run 01-create-workdocs-structure.sh"; fail=true; }
  [[ -d "$ONEDRIVE_ROOT" ]]       || { log "✗ OneDrive mount not found: $ONEDRIVE_ROOT"; fail=true; }

  $fail && exit 1
  log "✓ Preflight passed"
}

# ---------------------------------------------------------------------------
# Step 1 — rsync ~/WorkDocs → SharePoint
# ---------------------------------------------------------------------------
do_rsync() {
  log "── Step 1: rsync ~/WorkDocs → SharePoint ──────────────────────"

  local rsync_flags=(
    -a -h
    --exclude=".DS_Store"
    --exclude="._*"
    --exclude=".Spotlight-V100"
    --exclude=".Trashes"
    --log-file="$LOG_FILE"
  )

  $DRY_RUN && rsync_flags+=(--dry-run)

  mkdir -p "$WORKDOCS_SHAREPOINT"
  rsync "${rsync_flags[@]}" "${WORKDOCS_LOCAL}/" "${WORKDOCS_SHAREPOINT}/"

  log "✓ rsync complete"
}

# ---------------------------------------------------------------------------
# Step 2 — Check SharePoint quota usage
# Returns usage percentage as integer (e.g. 87)
# ---------------------------------------------------------------------------
check_quota() {
  log "── Step 2: SharePoint quota check ─────────────────────────────"

  local use_pct=0

  # Primary method: parse df Use% on the OneDrive mount
  # On macOS, the OneDrive client exposes SharePoint quota as filesystem size
  local df_pct
  df_pct=$(df -k "$ONEDRIVE_ROOT" 2>/dev/null \
    | awk 'NR==2 { gsub(/%/,"",$5); print $5 }' || echo "")

  if [[ -n "$df_pct" && "$df_pct" =~ ^[0-9]+$ && "$df_pct" -gt 0 ]]; then
    use_pct=$df_pct
    log "Quota (df method)   : ${use_pct}% used"
  else
    # Fallback: measure actual folder size vs configured quota
    local used_kb
    used_kb=$(du -sk "$WORKDOCS_SHAREPOINT" 2>/dev/null | awk '{print $1}' || echo 0)
    local quota_kb=$(( SHAREPOINT_QUOTA_GB * 1024 * 1024 ))
    if [[ $quota_kb -gt 0 ]]; then
      use_pct=$(( used_kb * 100 / quota_kb ))
    fi
    log "Quota (du fallback) : ${use_pct}% used  (${used_kb}K of ${quota_kb}K)"
  fi

  log "SharePoint usage: ${use_pct}%  (threshold: ${QUOTA_THRESHOLD_PCT}%)"
  echo "$use_pct"
}

# ---------------------------------------------------------------------------
# Step 3 — Emergency archive: zip WorkDocs → OCI, then clear SharePoint
# Triggered when usage >= QUOTA_THRESHOLD_PCT
# ---------------------------------------------------------------------------
do_emergency_archive() {
  log "── Step 3: EMERGENCY ARCHIVE — SharePoint at ${1}% ─────────────"
  log "Archiving WorkDocs from SharePoint to OCI and clearing space."

  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local archive_name="WorkDocs-full-backup-${timestamp}.tar.gz"
  local object_name="emergency/${archive_name}"
  local archive_file="${ARCHIVE_TMP}/${archive_name}"

  log "Archive : $object_name"
  log "Tier    : Standard  (emergency — may need immediate restore)"

  if $DRY_RUN; then
    local sp_size
    sp_size=$(du -sh "$WORKDOCS_SHAREPOINT" 2>/dev/null | cut -f1 || echo "unknown")
    log "DRY RUN: would compress $WORKDOCS_SHAREPOINT ($sp_size) → $archive_name"
    log "DRY RUN: would upload → oci://$BUCKET/$object_name [Standard]"
    log "DRY RUN: would clear $WORKDOCS_SHAREPOINT after verified upload"
    return 0
  fi

  # Compress
  mkdir -p "$ARCHIVE_TMP"
  log "Compressing $WORKDOCS_SHAREPOINT..."
  tar -czf "$archive_file" -C "$ONEDRIVE_ROOT" "WorkDocs" 2>> "$LOG_FILE"
  log "✓ Compressed: $(du -sh "$archive_file" | cut -f1) → $archive_file"

  # Upload to OCI with checksum verification
  log "Uploading to OCI..."
  if oci os object put \
      --namespace "$NAMESPACE" \
      --bucket-name "$BUCKET" \
      --region "$REGION" \
      --name "$object_name" \
      --file "$archive_file" \
      --storage-tier "Standard" \
      --verify-checksum \
      --force >> "$LOG_FILE" 2>&1; then

    log "✓ Upload verified: oci://$BUCKET/$object_name"

    # Clear SharePoint WorkDocs content — keep the folder itself
    log "Clearing WorkDocs from SharePoint to reclaim quota..."
    find "$WORKDOCS_SHAREPOINT" -mindepth 1 -delete 2>> "$LOG_FILE"
    log "✓ SharePoint WorkDocs cleared. Quota freed."

    # Clean up local staging
    rm -f "$archive_file"

    notify "WorkDocs Emergency Archive" \
      "SharePoint was at ${1}%. WorkDocs archived to OCI and SharePoint cleared."

  else
    log "✗ OCI upload FAILED — SharePoint NOT cleared. Manual intervention required."
    rm -f "$archive_file"
    notify "WorkDocs Archive FAILED" \
      "SharePoint at ${1}% — OCI upload failed. Check log: $LOG_FILE"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  WorkDocs Weekly Sync + Quota Monitor"
echo "  $(date)"
if $DRY_RUN; then
  echo "  MODE: *** DRY RUN — NO CHANGES WILL BE MADE ***"
else
  echo "  MODE: *** LIVE RUN ***"
fi
echo "  Log : $LOG_FILE"
echo "═══════════════════════════════════════════════════════"
echo ""

log "=== WorkDocs Weekly Run Start ==="

preflight
do_rsync

USE_PCT=$(check_quota)

if [[ "$USE_PCT" -ge "$QUOTA_THRESHOLD_PCT" ]]; then
  log "⚠  SharePoint at ${USE_PCT}% — at or above ${QUOTA_THRESHOLD_PCT}% threshold. Triggering emergency archive."
  do_emergency_archive "$USE_PCT"
else
  log "✓ SharePoint at ${USE_PCT}% — below ${QUOTA_THRESHOLD_PCT}% threshold. No archive needed."
  if ! $DRY_RUN; then
    notify "WorkDocs Weekly Sync" \
      "Sync complete. SharePoint at ${USE_PCT}% of quota."
  fi
fi

log "=== WorkDocs Weekly Run Complete ==="
echo ""
