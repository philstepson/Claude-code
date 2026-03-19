#!/usr/bin/env bash
# =============================================================================
# 01-create-workdocs-structure.sh
#
# Creates the WorkDocs folder hierarchy locally under a target directory.
# Run this BEFORE migrating to SharePoint so the structure is ready to
# reorganise files into.
#
# Usage:
#   chmod +x 01-create-workdocs-structure.sh
#   ./01-create-workdocs-structure.sh                    # defaults to ~/WorkDocs
#   ./01-create-workdocs-structure.sh /path/to/target    # custom location
#
# After running, manually move files from ~/Downloads into the new folders,
# then run 02-migrate-to-sharepoint.sh to push everything up.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Target root — override by passing a path as the first argument
# ---------------------------------------------------------------------------
TARGET="${1:-$HOME/WorkDocs}"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  WorkDocs Structure Builder"
echo "  Target: $TARGET"
echo "═══════════════════════════════════════════════════════"
echo ""

# ---------------------------------------------------------------------------
# Safety check — don't clobber an existing directory without confirmation
# ---------------------------------------------------------------------------
if [[ -d "$TARGET" ]]; then
  read -rp "  ⚠  '$TARGET' already exists. Continue and add missing folders? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Helper — creates a directory and prints a status line
# ---------------------------------------------------------------------------
mkd() {
  mkdir -p "$1"
  echo "  ✓  $1"
}

# ---------------------------------------------------------------------------
# Generic data-type folders
# ---------------------------------------------------------------------------
echo "→ Data-type folders"
mkd "$TARGET/Excel"
mkd "$TARGET/Images"
mkd "$TARGET/JSON"
mkd "$TARGET/PPT"
mkd "$TARGET/Python"
mkd "$TARGET/Shells"
mkd "$TARGET/SQL"
mkd "$TARGET/TXT"
mkd "$TARGET/Word"

# ---------------------------------------------------------------------------
# General catch-all
# ---------------------------------------------------------------------------
echo ""
echo "→ General catch-all"
mkd "$TARGET/General"

# ---------------------------------------------------------------------------
# Customer folders  — add or remove customers as needed
# Each gets a General/ sub-folder as the default landing zone.
# Add named project sub-folders manually or extend the PROJECTS map below.
# ---------------------------------------------------------------------------
echo ""
echo "→ Customer folders"

declare -A PROJECTS
PROJECTS["CO-Calvert"]="General"
PROJECTS["CO-FuelQuest"]="General"
PROJECTS["CO-Kubota"]="General"
PROJECTS["CO-Olympus"]="General"

for CUSTOMER in "${!PROJECTS[@]}"; do
  IFS=',' read -ra SUBS <<< "${PROJECTS[$CUSTOMER]}"
  for SUB in "${SUBS[@]}"; do
    SUB_TRIMMED="$(echo -e "${SUB}" | tr -d '[:space:]')"
    mkd "$TARGET/$CUSTOMER/$SUB_TRIMMED"
  done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Done. Structure created at: $TARGET"
echo ""
echo "  Next steps:"
echo "  1. Reorganise files from ~/Downloads into $TARGET"
echo "  2. Run 02-migrate-to-sharepoint.sh to upload to SharePoint"
echo "═══════════════════════════════════════════════════════"
echo ""
