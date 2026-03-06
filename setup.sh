#!/bin/bash
set -euo pipefail

REPO="Comfy-Org/ComfyUI_frontend"
WORK_DIR="$HOME/works/comfy-ui/coderabbit-fixer"
REPO_DIR="$WORK_DIR/repo"
STATE_FILE="$WORK_DIR/processed_issues.txt"
LOG_DIR="$WORK_DIR/logs"
SCRIPT="$WORK_DIR/fix-issues.sh"

echo "=== CodeRabbit Issue Auto-Fixer Setup ==="

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI not found. Install it: https://cli.github.com/"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "ERROR: gh is not authenticated. Run: gh auth login"
  exit 1
fi
echo "  gh CLI: OK"

if ! command -v claude &>/dev/null; then
  echo "ERROR: claude CLI not found. Install it: https://docs.anthropic.com/en/docs/claude-code"
  exit 1
fi
echo "  claude CLI: OK"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install it: brew install jq"
  exit 1
fi
echo "  jq: OK"

# Create directory structure
echo "Creating directory structure..."
mkdir -p "$LOG_DIR"
touch "$STATE_FILE"
echo "  Directories: OK"

# Clone repo if needed
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Cloning $REPO..."
  gh repo clone "$REPO" "$REPO_DIR"
  echo "  Repo cloned: OK"
else
  echo "  Repo already exists: OK"
fi

# Make scripts executable
chmod +x "$SCRIPT"
echo "  Scripts: OK"

# Copy CLAUDE.md into repo
CLAUDE_MD="$WORK_DIR/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
  cp "$CLAUDE_MD" "$REPO_DIR/CLAUDE.md"
  echo "  CLAUDE.md copied to repo: OK"
fi

# Show cron setup instructions
CRON_ENTRY="*/30 * * * * $SCRIPT >> $LOG_DIR/cron.log 2>&1"
echo ""
echo "=== Setup Complete ==="
echo ""
echo "To run manually:"
echo "  $SCRIPT"
echo ""
echo "To set up cron (every 30 minutes), run:"
echo "  crontab -e"
echo "  Then add this line:"
echo "  $CRON_ENTRY"
echo ""
echo "Or run this to add it automatically:"
echo "  (crontab -l 2>/dev/null; echo '$CRON_ENTRY') | crontab -"
