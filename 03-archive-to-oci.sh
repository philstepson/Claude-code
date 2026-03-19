#!/usr/bin/env bash
# =============================================================================
# 03-archive-to-oci.sh
#
# Archives WorkDocs content from the SharePoint OneDrive mount to OCI Object
# Storage (bucket: workdocs-archive, compartment: philip.stephenson).
#
# Two archive modes:
#
#   --customer <folder>
#       Archive an entire CO-* customer folder. Use when a sales cycle ends or
#       a customer goes dormant. Compresses to .tar.gz, uploads at
#       InfrequentAccess tier (fast restore if the customer re-engages).
#
#   --age-out <days>
#       Archive files in data-type folders (PPT, Excel, Word, etc.) not
#       modified in the last <days> days. Use when old product-release content
#       needs clearing out. Uploads at Archive tier (lowest cost, cold storage).
#
# Both modes default to DRY RUN — safe to run at any time.
# Pass --go to execute for real.
#
# Usage:
#   chmod +x 03-archive-to-oci.sh
#   ./03-archive-to-oci.sh --customer CO-Calvert           # dry run
#   ./03-archive-to-oci.sh --customer CO-Calvert --go      # archive customer
#   ./03-archive-to-oci.sh --age-out 180                   # dry run, files >180 days
#   ./03-archive-to-oci.sh --age-out 180 --go              # archive aged files
#   ./03-archive-to-oci.sh --list                          # list OCI archive contents
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# OCI configuration — philip.stephenson / us-phoenix-1
# ---------------------------------------------------------------------------
NAMESPACE="axxduehrw7lz"
REGION="us-phoenix-1"
COMPARTMENT_OCID="ocid1.compartment.oc1..aaaaaaaa4gxfntpkf65wzzoddjuak6fk4emk6fj2t2pmf6bpglotjjhk436a"
BUCKET="workdocs-archive"

# ---------------------------------------------------------------------------
# Local paths
# ---------------------------------------------------------------------------
ONEDRIVE_WORKDOCS="$HOME/Library/CloudStorage/OneDrive-OracleCorporation/WorkDocs"
ARCHIVE_TMP="${TMPDIR:-/tmp}/workdocs-archive-staging"
LOG_FILE="$HOME/workdocs-archive-$(date +%Y%m%d-%H%M%S).log"

# Data-type folders eligible for age-out (customer folders are never auto-aged)
AGEABLE_TYPES=("PPT" "Excel" "Word" "TXT" "JSON" "SQL" "Shells" "Python" "Images")

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE=""
CUSTOMER=""
AGE_DAYS=180
DRY_RUN=true

NEXT_IS_CUSTOMER=false
NEXT_IS_DAYS=false

for arg in "$@"; do
  if $NEXT_IS_CUSTOMER; then
    CUSTOMER="$arg"
    NEXT_IS_CUSTOMER=false
    continue
  fi
  if $NEXT_IS_DAYS; then
    AGE_DAYS="$arg"
    NEXT_IS_DAYS=false
    continue
  fi
  case "$arg" in
    --go|-go)               DRY_RUN=false ;;
    --list|-list)           MODE="list" ;;
    --customer|-customer)   MODE="customer"; NEXT_IS_CUSTOMER=true ;;
    --age-out|-age-out)     MODE="ageout";   NEXT_IS_DAYS=true ;;
    --help|-help|-h)
      grep '^#' "$0" | head -35 | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging — writes to both stdout and log file
# ---------------------------------------------------------------------------
log() {
  local msg="[$(date '+%Y/%m/%d %H:%M:%S')] $*"
  echo "  $msg" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  if ! command -v oci &>/dev/null; then
    echo ""
    echo "  ✗  OCI CLI not found in PATH."
    echo "     Install: https://docs.oracle.com/en-us/iaas/tools/oci-cli/"
    echo ""
    exit 1
  fi

  if [[ ! -d "$ONEDRIVE_WORKDOCS" ]]; then
    echo ""
    echo "  ✗  SharePoint mount not found: $ONEDRIVE_WORKDOCS"
    echo "     Ensure the OneDrive app is running and signed in to your Oracle account."
    echo ""
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Ensure the archive bucket exists (idempotent)
# ---------------------------------------------------------------------------
ensure_bucket() {
  local exists
  exists=$(oci os bucket list \
    --namespace "$NAMESPACE" \
    --compartment-id "$COMPARTMENT_OCID" \
    --region "$REGION" \
    --query "data[?name=='$BUCKET'].name | [0]" \
    --raw-output 2>/dev/null || echo "")

  if [[ -z "$exists" || "$exists" == "null" ]]; then
    if $DRY_RUN; then
      log "DRY RUN: would create bucket '$BUCKET' in philip.stephenson"
    else
      log "Creating bucket '$BUCKET' in philip.stephenson (region: $REGION)..."
      oci os bucket create \
        --namespace "$NAMESPACE" \
        --compartment-id "$COMPARTMENT_OCID" \
        --name "$BUCKET" \
        --region "$REGION" >> "$LOG_FILE" 2>&1
      log "✓ Bucket '$BUCKET' created."
    fi
  else
    log "✓ Bucket '$BUCKET' confirmed."
  fi
}

# ---------------------------------------------------------------------------
# Compress a source path to a .tar.gz in ARCHIVE_TMP
# Usage: compress_path <source_path> <archive_filename>
# ---------------------------------------------------------------------------
compress_path() {
  local src="$1"
  local archive_file="$2"
  local parent
  local basename_src

  parent="$(dirname "$src")"
  basename_src="$(basename "$src")"

  mkdir -p "$ARCHIVE_TMP"
  log "Compressing: $src"
  tar -czf "$archive_file" -C "$parent" "$basename_src" 2>> "$LOG_FILE"
  log "✓ Compressed → $(basename "$archive_file") ($(du -sh "$archive_file" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Compress a list of files (full paths) into a single .tar.gz
# Usage: compress_filelist <file_list_path> <archive_filename>
# ---------------------------------------------------------------------------
compress_filelist() {
  local file_list="$1"
  local archive_file="$2"

  mkdir -p "$ARCHIVE_TMP"
  log "Compressing $(wc -l < "$file_list" | tr -d ' ') files..."
  tar -czf "$archive_file" --files-from="$file_list" 2>> "$LOG_FILE"
  log "✓ Compressed → $(basename "$archive_file") ($(du -sh "$archive_file" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Upload to OCI with checksum verification
# Returns 0 on success, 1 on failure
# ---------------------------------------------------------------------------
upload_and_verify() {
  local archive_file="$1"
  local object_name="$2"
  local storage_tier="$3"

  log "Uploading → oci://$BUCKET/$object_name [tier: $storage_tier]"

  if $DRY_RUN; then
    log "DRY RUN: would upload $(du -sh "$archive_file" | cut -f1) → $object_name"
    return 0
  fi

  oci os object put \
    --namespace "$NAMESPACE" \
    --bucket-name "$BUCKET" \
    --region "$REGION" \
    --name "$object_name" \
    --file "$archive_file" \
    --storage-tier "$storage_tier" \
    --verify-checksum \
    --force >> "$LOG_FILE" 2>&1

  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    log "✓ Upload verified (checksum matched): $object_name"
    return 0
  else
    log "✗ Upload FAILED (exit $exit_code): $object_name"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# MODE: --list  — show what is already archived in OCI
# ---------------------------------------------------------------------------
do_list() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  OCI Archive Contents  →  oci://$BUCKET"
  echo "  Namespace : $NAMESPACE  |  Region: $REGION"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  oci os object list \
    --namespace "$NAMESPACE" \
    --bucket-name "$BUCKET" \
    --region "$REGION" \
    --query 'data[*].{Object:name, Size:size, Tier:"storage-tier", Modified:"time-modified"}' \
    --output table 2>/dev/null \
    || echo "  (bucket is empty or does not exist yet)"

  echo ""
}

# ---------------------------------------------------------------------------
# MODE: --customer  — archive an entire CO-* folder
# ---------------------------------------------------------------------------
do_customer_archive() {
  local customer="$1"
  local src="$ONEDRIVE_WORKDOCS/$customer"
  local timestamp
  timestamp=$(date +%Y-%m)
  local archive_name="${customer}-archived-${timestamp}.tar.gz"
  local object_name="customers/${archive_name}"
  local archive_file="${ARCHIVE_TMP}/${archive_name}"

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Customer Archive: $customer"
  if $DRY_RUN; then
    echo "  MODE: *** DRY RUN — NO CHANGES WILL BE MADE ***"
  else
    echo "  MODE: *** LIVE RUN ***"
  fi
  echo ""
  echo "  Source  : $src"
  echo "  Object  : oci://$BUCKET/$object_name"
  echo "  Tier    : InfrequentAccess  (fast restore if customer re-engages)"
  echo "  Log     : $LOG_FILE"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  if [[ ! -d "$src" ]]; then
    echo "  ✗  Customer folder not found: $src"
    echo "     Available customer folders:"
    ls "$ONEDRIVE_WORKDOCS" | grep '^CO-' | sed 's/^/     /'
    exit 1
  fi

  local file_count
  file_count=$(find "$src" -type f | wc -l | tr -d ' ')
  local src_size
  src_size=$(du -sh "$src" | cut -f1)
  log "Source: $file_count files, $src_size uncompressed"

  ensure_bucket

  if $DRY_RUN; then
    log "DRY RUN: would compress $src ($src_size) → $object_name"
    log "DRY RUN: would upload → oci://$BUCKET/$object_name [InfrequentAccess]"
    log "DRY RUN: would remove $src from SharePoint after verified upload"
  else
    compress_path "$src" "$archive_file"

    if upload_and_verify "$archive_file" "$object_name" "InfrequentAccess"; then
      log "Removing from SharePoint: $src"
      rm -rf "$src"
      log "✓ $customer archived and removed from SharePoint."
      rm -f "$archive_file"
    else
      log "✗ Upload failed — $src NOT deleted. Check log: $LOG_FILE"
      rm -f "$archive_file"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# MODE: --age-out  — archive data-type files older than N days
# ---------------------------------------------------------------------------
do_age_out() {
  local days="$1"
  local timestamp
  timestamp=$(date +%Y-%m)

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Data-Type Age-Out: files not modified in $days+ days"
  if $DRY_RUN; then
    echo "  MODE: *** DRY RUN — NO CHANGES WILL BE MADE ***"
  else
    echo "  MODE: *** LIVE RUN ***"
  fi
  echo ""
  echo "  Scanning : ${AGEABLE_TYPES[*]}"
  echo "  Tier     : Archive  (cold storage, lowest cost)"
  echo "  Log      : $LOG_FILE"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  ensure_bucket

  local any_found=false

  for type_folder in "${AGEABLE_TYPES[@]}"; do
    local src="$ONEDRIVE_WORKDOCS/$type_folder"
    [[ -d "$src" ]] || { log "Skipping $type_folder (folder not found)"; continue; }

    # Collect files older than $days days
    local file_list="${ARCHIVE_TMP}/${type_folder}-filelist.txt"
    mkdir -p "$ARCHIVE_TMP"
    find "$src" -type f -mtime "+$days" > "$file_list" 2>/dev/null || true

    local count
    count=$(wc -l < "$file_list" | tr -d ' ')

    if [[ "$count" -eq 0 ]]; then
      log "$type_folder: no files older than $days days — skipping"
      rm -f "$file_list"
      continue
    fi

    any_found=true
    local src_size
    src_size=$(du -sh "$src" | cut -f1)
    log "$type_folder: found $count file(s) older than $days days"

    local archive_name="${type_folder}-aged-out-${timestamp}.tar.gz"
    local object_name="datatypes/${archive_name}"
    local archive_file="${ARCHIVE_TMP}/${archive_name}"

    if $DRY_RUN; then
      log "DRY RUN: would compress $count file(s) → $object_name [Archive tier]"
      while IFS= read -r f; do
        log "  would archive: $f"
      done < "$file_list"
      rm -f "$file_list"
      continue
    fi

    compress_filelist "$file_list" "$archive_file"

    if upload_and_verify "$archive_file" "$object_name" "Archive"; then
      log "Removing $count aged file(s) from $type_folder..."
      while IFS= read -r f; do
        rm -f "$f"
        log "  removed: $(basename "$f")"
      done < "$file_list"
      log "✓ Age-out complete for $type_folder"
      rm -f "$archive_file" "$file_list"
    else
      log "✗ Upload failed for $type_folder — source files NOT deleted."
      rm -f "$archive_file" "$file_list"
    fi
  done

  if ! $any_found; then
    log "No files found older than $days days in any data-type folder."
  fi
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
preflight

case "$MODE" in
  list)
    do_list
    ;;
  customer)
    [[ -n "$CUSTOMER" ]] || {
      echo "  ✗  Specify a customer folder: --customer CO-Calvert"
      exit 1
    }
    do_customer_archive "$CUSTOMER"
    ;;
  ageout)
    do_age_out "$AGE_DAYS"
    ;;
  *)
    echo ""
    echo "  Usage:"
    echo "    $(basename "$0") --customer CO-Calvert [--go]"
    echo "        Archive a dormant customer folder to OCI InfrequentAccess"
    echo ""
    echo "    $(basename "$0") --age-out 180 [--go]"
    echo "        Archive data-type files older than 180 days to OCI Archive tier"
    echo ""
    echo "    $(basename "$0") --list"
    echo "        List all archived objects in oci://$BUCKET"
    echo ""
    exit 1
    ;;
esac

echo ""
log "Done. Full log: $LOG_FILE"
echo ""
