#!/usr/bin/env bash
# =============================================================================
# 04-set-lifecycle-policy.sh
#
# Applies an OCI Object Storage lifecycle policy to the workdocs-archive bucket.
# All transitions are automatic and server-side — no local process needs to run.
#
# Lifecycle tiers and flow:
#
#   customers/   InfrequentAccess  →  Archive  (after CUSTOMER_TO_ARCHIVE_DAYS)
#                Archive           →  DELETE   (after RETENTION_DAYS)
#
#   datatypes/   Archive (already cold on upload)
#                Archive           →  DELETE   (after RETENTION_DAYS)
#
#   (all)        Any tier          →  DELETE   (after RETENTION_DAYS)
#
# OCI Archive tier notes:
#   - Lowest cost storage — approximately 1/10th of Standard
#   - Objects are retrievable but require a restore request first
#   - Standard restore: up to 1 hour  |  Bulk restore: up to 12 hours
#   - Use 03-archive-to-oci.sh --restore (future) to initiate a restore
#
# Usage:
#   chmod +x 04-set-lifecycle-policy.sh
#   ./04-set-lifecycle-policy.sh           # show current policy (read-only)
#   ./04-set-lifecycle-policy.sh --apply   # apply the policy to the bucket
#   ./04-set-lifecycle-policy.sh --show    # show policy after applying
#   ./04-set-lifecycle-policy.sh --delete  # remove policy from bucket
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# OCI configuration — philip.stephenson / us-phoenix-1
# ---------------------------------------------------------------------------
NAMESPACE="axxduehrw7lz"
REGION="us-phoenix-1"
BUCKET="workdocs-archive"

# ---------------------------------------------------------------------------
# Lifecycle thresholds — adjust to match Oracle data retention requirements
#
# CUSTOMER_TO_ARCHIVE_DAYS
#   Days after upload before a customers/ object transitions from
#   InfrequentAccess → Archive. Default: 90 days. This gives a 3-month
#   window for quick restore if a dormant customer re-engages, after which
#   they drop to deep freeze.
#
# RETENTION_DAYS
#   Days after upload before any object is permanently deleted.
#   Default: 2555 days (7 years) — a common Oracle business records
#   retention baseline. Adjust to match your specific compliance requirement.
# ---------------------------------------------------------------------------
CUSTOMER_TO_ARCHIVE_DAYS=90
RETENTION_DAYS=2555   # 7 years — verify with Oracle data retention policy

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE="preview"

for arg in "$@"; do
  case "$arg" in
    --apply|-apply)   MODE="apply" ;;
    --show|-show)     MODE="show" ;;
    --delete|-delete) MODE="delete" ;;
    --help|-help|-h)
      grep '^#' "$0" | head -40 | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Build the lifecycle policy JSON
#
# Rules:
#   1. archive-customers   — customers/* InfrequentAccess → Archive
#   2. expire-customers    — customers/* → DELETE after RETENTION_DAYS
#   3. expire-datatypes    — datatypes/* → DELETE after RETENTION_DAYS
#      (datatypes are already uploaded at Archive tier by script 03,
#       so no tier transition needed — just the eventual delete)
# ---------------------------------------------------------------------------
build_policy_json() {
  cat <<EOF
[
  {
    "action": "ARCHIVE",
    "isEnabled": true,
    "name": "archive-customers-to-deep-freeze",
    "objectNameFilter": {
      "inclusionPrefixes": ["customers/"]
    },
    "timeAmount": ${CUSTOMER_TO_ARCHIVE_DAYS},
    "timeUnit": "DAYS"
  },
  {
    "action": "DELETE",
    "isEnabled": true,
    "name": "expire-customers-after-retention",
    "objectNameFilter": {
      "inclusionPrefixes": ["customers/"]
    },
    "timeAmount": ${RETENTION_DAYS},
    "timeUnit": "DAYS"
  },
  {
    "action": "DELETE",
    "isEnabled": true,
    "name": "expire-datatypes-after-retention",
    "objectNameFilter": {
      "inclusionPrefixes": ["datatypes/"]
    },
    "timeAmount": ${RETENTION_DAYS},
    "timeUnit": "DAYS"
  }
]
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! command -v oci &>/dev/null; then
  echo ""
  echo "  ✗  OCI CLI not found in PATH."
  exit 1
fi

# ---------------------------------------------------------------------------
# Preview — show what policy would be applied, no changes
# ---------------------------------------------------------------------------
do_preview() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  WorkDocs Archive — Lifecycle Policy Preview"
  echo "  Bucket : oci://$BUCKET  |  Region: $REGION"
  echo "═══════════════════════════════════════════════════════"
  echo ""
  echo "  The following rules would be applied:"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────┐"
  echo "  │  customers/*                                                │"
  echo "  │                                                             │"
  echo "  │  Day 0        →  InfrequentAccess  (uploaded by script 03) │"
  echo "  │  Day $CUSTOMER_TO_ARCHIVE_DAYS       →  Archive             (auto-transition)    │"
  echo "  │  Day $RETENTION_DAYS   →  DELETED              (retention expiry)     │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────┐"
  echo "  │  datatypes/*                                                │"
  echo "  │                                                             │"
  echo "  │  Day 0        →  Archive            (uploaded by script 03) │"
  echo "  │  Day $RETENTION_DAYS   →  DELETED              (retention expiry)     │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  Thresholds:"
  printf "    %-40s %s days\n" "InfrequentAccess → Archive (customers):" "$CUSTOMER_TO_ARCHIVE_DAYS"
  printf "    %-40s %s days (%s years)\n" "Archive → DELETE (all):" "$RETENTION_DAYS" "$(( RETENTION_DAYS / 365 ))"
  echo ""
  echo "  Run with --apply to set this policy on the bucket."
  echo ""
}

# ---------------------------------------------------------------------------
# Apply — write the policy to the bucket
# ---------------------------------------------------------------------------
do_apply() {
  local policy_json
  policy_json=$(build_policy_json)

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Applying Lifecycle Policy → oci://$BUCKET"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  oci os object-lifecycle-policy put \
    --namespace "$NAMESPACE" \
    --bucket-name "$BUCKET" \
    --region "$REGION" \
    --items "$policy_json" \
    --force

  echo ""
  echo "  ✓  Lifecycle policy applied successfully."
  echo ""
  echo "  Rules active:"
  printf "    %-45s after %s days\n" "customers/* InfrequentAccess → Archive:" "$CUSTOMER_TO_ARCHIVE_DAYS"
  printf "    %-45s after %s days\n" "customers/* → DELETE:" "$RETENTION_DAYS"
  printf "    %-45s after %s days\n" "datatypes/* → DELETE:" "$RETENTION_DAYS"
  echo ""
  echo "  OCI evaluates lifecycle rules daily — transitions happen automatically."
  echo "  Run with --show to confirm the policy as stored."
  echo ""
}

# ---------------------------------------------------------------------------
# Show — read back the current policy from OCI
# ---------------------------------------------------------------------------
do_show() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Current Lifecycle Policy on oci://$BUCKET"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  oci os object-lifecycle-policy get \
    --namespace "$NAMESPACE" \
    --bucket-name "$BUCKET" \
    --region "$REGION" 2>/dev/null \
    || echo "  (no lifecycle policy set on this bucket)"

  echo ""
}

# ---------------------------------------------------------------------------
# Delete — remove the lifecycle policy from the bucket
# ---------------------------------------------------------------------------
do_delete() {
  echo ""
  echo "  Removing lifecycle policy from oci://$BUCKET..."
  echo ""

  oci os object-lifecycle-policy delete \
    --namespace "$NAMESPACE" \
    --bucket-name "$BUCKET" \
    --region "$REGION" \
    --force

  echo ""
  echo "  ✓  Lifecycle policy removed. Objects will no longer auto-transition."
  echo ""
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$MODE" in
  preview) do_preview ;;
  apply)   do_apply   ;;
  show)    do_show    ;;
  delete)  do_delete  ;;
esac
