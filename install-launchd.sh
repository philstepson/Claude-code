#!/usr/bin/env bash
# =============================================================================
# install-launchd.sh
#
# Installs the WorkDocs weekly sync as a macOS launchd agent.
# Run once after placing your scripts in ~/scripts/workdocs/.
#
# Usage:
#   chmod +x install-launchd.sh
#   ./install-launchd.sh           # install and activate
#   ./install-launchd.sh --remove  # deactivate and uninstall
# =============================================================================

set -euo pipefail

PLIST_NAME="com.oracle.workdocs-weeklysync.plist"
PLIST_SRC="$(dirname "$0")/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
SCRIPTS_DIR="$HOME/scripts/workdocs"
SCRIPT_TARGET="$SCRIPTS_DIR/05-weekly-sync-and-monitor.sh"
LOG_DIR="$HOME/Library/Logs"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  WorkDocs Weekly Sync — launchd Agent Installer"
echo "═══════════════════════════════════════════════════════"
echo ""

# ---------------------------------------------------------------------------
# Remove mode
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
  echo "  Unloading and removing launchd agent..."

  if launchctl list | grep -q "com.oracle.workdocs-weeklysync"; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    echo "  ✓ Agent unloaded"
  fi

  [[ -f "$PLIST_DEST" ]] && rm -f "$PLIST_DEST" && echo "  ✓ Plist removed"

  echo ""
  echo "  Weekly sync has been disabled."
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# Install mode
# ---------------------------------------------------------------------------

# 1. Verify the main script exists
if [[ ! -f "$SCRIPT_TARGET" ]]; then
  echo "  ✗  Script not found: $SCRIPT_TARGET"
  echo ""
  echo "  Move your workdocs scripts to $SCRIPTS_DIR first:"
  echo ""
  echo "    mkdir -p $SCRIPTS_DIR"
  echo "    cp 0*.sh $SCRIPTS_DIR/"
  echo "    chmod +x $SCRIPTS_DIR/*.sh"
  echo ""
  exit 1
fi

# 2. Verify the plist source is present
if [[ ! -f "$PLIST_SRC" ]]; then
  echo "  ✗  Plist not found: $PLIST_SRC"
  echo "     Run this script from the folder containing $PLIST_NAME"
  exit 1
fi

# 3. Unload existing agent if present (clean reinstall)
if launchctl list 2>/dev/null | grep -q "com.oracle.workdocs-weeklysync"; then
  echo "  → Existing agent found — unloading for clean reinstall..."
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# 4. Copy plist to LaunchAgents
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DEST"
echo "  ✓ Plist copied → $PLIST_DEST"

# 5. Ensure log directory exists
mkdir -p "$LOG_DIR"
echo "  ✓ Log directory ready → $LOG_DIR"

# 6. Load the agent
launchctl load "$PLIST_DEST"
echo "  ✓ Agent loaded — will run every Sunday at midnight"

# 7. Confirm it registered
echo ""
if launchctl list | grep -q "com.oracle.workdocs-weeklysync"; then
  echo "  ✓ Agent registered with launchd:"
  launchctl list | grep "com.oracle.workdocs-weeklysync"
else
  echo "  ⚠  Agent may not have loaded. Check:"
  echo "     launchctl list | grep workdocs"
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Next scheduled run: Sunday at midnight (00:00)"
echo ""
echo "  Useful commands:"
echo "    Check status  : launchctl list | grep workdocs"
echo "    Run now       : launchctl start com.oracle.workdocs-weeklysync"
echo "    View logs     : tail -f $LOG_DIR/workdocs-weekly-launchd.log"
echo "    Uninstall     : $0 --remove"
echo "═══════════════════════════════════════════════════════"
echo ""
