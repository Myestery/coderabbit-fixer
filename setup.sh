#!/bin/bash
set -euo pipefail

REPO="Comfy-Org/ComfyUI_frontend"
WORK_DIR="/var/www/coderabbit-fixer"
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
  echo "ERROR: jq not found. Install it: sudo apt install jq"
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

# Install systemd service and timer
echo "Installing systemd service and timer..."

SERVICE_FILE="/etc/systemd/system/coderabbit-fixer.service"
TIMER_FILE="/etc/systemd/system/coderabbit-fixer.timer"

sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=CodeRabbit Issue Auto-Fixer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT
WorkingDirectory=$WORK_DIR
User=$(whoami)
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/$(whoami)/.local/bin:/home/$(whoami)/.npm-global/bin
Environment=HOME=/home/$(whoami)

[Install]
WantedBy=multi-user.target
EOF

sudo tee "$TIMER_FILE" > /dev/null << EOF
[Unit]
Description=Run CodeRabbit Issue Auto-Fixer every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable coderabbit-fixer.timer
sudo systemctl start coderabbit-fixer.timer

echo "  systemd timer: OK"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Manage with:"
echo "  sudo systemctl status coderabbit-fixer.timer   # timer status"
echo "  sudo systemctl list-timers coderabbit-fixer*    # next run time"
echo "  sudo systemctl start coderabbit-fixer.service   # run now"
echo "  journalctl -u coderabbit-fixer.service -f       # follow logs"
echo "  sudo systemctl stop coderabbit-fixer.timer      # stop scheduling"
echo "  sudo systemctl disable coderabbit-fixer.timer   # disable on boot"
