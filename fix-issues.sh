#!/bin/bash
set -euo pipefail

REPO="Comfy-Org/ComfyUI_frontend"
WORK_DIR="/var/www/coderabbit-fixer"
REPO_DIR="$WORK_DIR/repo"
STATE_FILE="$WORK_DIR/processed_issues.txt"
LOG_DIR="$WORK_DIR/logs"
LOCK_FILE="$WORK_DIR/.lock"
CLAUDE_TIMEOUT=900 # 15 minutes

LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cleanup() {
  rm -f "$LOCK_FILE"
}

# Acquire lock
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "Another instance is running (PID $LOCK_PID). Exiting."
    exit 0
  fi
  echo "Stale lock file found. Removing."
  rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"
trap cleanup EXIT

# Ensure directories exist
mkdir -p "$LOG_DIR"
touch "$STATE_FILE"

log "Starting coderabbit-fixer run"

# Ensure repo is cloned
if [ ! -d "$REPO_DIR/.git" ]; then
  log "Cloning $REPO..."
  gh repo clone "$REPO" "$REPO_DIR"
fi

cd "$REPO_DIR"

# Update main
git checkout main 2>/dev/null || git checkout master
git pull --ff-only
log "Repo updated to latest main"

# Fetch open issues by coderabbitai bot
# Note: --author filter for bot accounts may not work on all gh versions,
# so we fetch all recent issues and filter with jq
ALL_ISSUES=$(gh issue list --repo "$REPO" --state open --json number,title,body,labels,author --limit 100)
ISSUES_JSON=$(echo "$ALL_ISSUES" | jq '[.[] | select(.author.login == "app/coderabbitai")]')
ISSUE_COUNT=$(echo "$ISSUES_JSON" | jq length)
log "Found $ISSUE_COUNT open issues by coderabbitai"

if [ "$ISSUE_COUNT" -eq 0 ]; then
  log "No issues to process. Done."
  exit 0
fi

# Process each issue
echo "$ISSUES_JSON" | jq -c '.[]' | while read -r issue; do
  ISSUE_NUM=$(echo "$issue" | jq -r '.number')
  ISSUE_TITLE=$(echo "$issue" | jq -r '.title')
  ISSUE_BODY=$(echo "$issue" | jq -r '.body')

  # Skip already processed issues
  if grep -qx "$ISSUE_NUM" "$STATE_FILE" 2>/dev/null; then
    log "Issue #$ISSUE_NUM already processed. Skipping."
    continue
  fi

  log "Processing issue #$ISSUE_NUM: $ISSUE_TITLE"

  # Reset to main
  git checkout main 2>/dev/null || git checkout master
  git pull --ff-only

  # Create feature branch
  BRANCH="fix/coderabbit-issue-${ISSUE_NUM}"
  git checkout -b "$BRANCH" 2>/dev/null || {
    git branch -D "$BRANCH"
    git checkout -b "$BRANCH"
  }

  # Run Claude to fix the issue
  log "Invoking Claude for issue #$ISSUE_NUM..."

  PROMPT_FILE=$(mktemp)
  cat > "$PROMPT_FILE" <<PROMPT_EOF
Fix the following GitHub issue (#$ISSUE_NUM):

Title: $ISSUE_TITLE

$ISSUE_BODY

Instructions:
- Make minimal changes to fix the issue
- Run pnpm lint:fix and pnpm typecheck after making changes
- Do not modify unrelated code
- Follow existing code conventions in AGENTS.md
PROMPT_EOF

  CLAUDE_EXIT=0
  timeout "$CLAUDE_TIMEOUT" cat "$PROMPT_FILE" | claude --dangerously-skip-permissions -p >> "$LOG_FILE" 2>&1 || CLAUDE_EXIT=$?
  rm -f "$PROMPT_FILE"

  if [ "$CLAUDE_EXIT" -ne 0 ]; then
    log "Claude failed or timed out for issue #$ISSUE_NUM (exit code: $CLAUDE_EXIT). Will retry next cycle."
    git checkout main 2>/dev/null || git checkout master
    git branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi

  # Check if Claude made any changes
  if git diff --quiet && git diff --cached --quiet; then
    log "No changes made for issue #$ISSUE_NUM. Will retry next cycle."
    git checkout main 2>/dev/null || git checkout master
    git branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi

  # Stage and commit changes
  git add -A
  if git diff --cached --quiet; then
    log "No staged changes for issue #$ISSUE_NUM. Will retry next cycle."
    git checkout main 2>/dev/null || git checkout master
    git branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi

  git commit -m "fix: address CodeRabbit issue #$ISSUE_NUM

$ISSUE_TITLE"

  # Push branch
  git push origin "$BRANCH" --force-with-lease

  # Create draft PR
  ISSUE_PREVIEW=$(echo "$ISSUE_BODY" | head -20)
  PR_URL=$(gh pr create \
    --repo "$REPO" \
    --draft \
    --title "fix: address CodeRabbit issue #$ISSUE_NUM" \
    --body "Automated fix for #$ISSUE_NUM

$ISSUE_PREVIEW

---
Automated by coderabbit-fixer" 2>&1) || {
    log "Failed to create PR for issue #$ISSUE_NUM: $PR_URL"
    git checkout main 2>/dev/null || git checkout master
    continue
  }

  log "Created draft PR: $PR_URL"

  # Mark issue as processed
  echo "$ISSUE_NUM" >> "$STATE_FILE"

  # Return to main
  git checkout main 2>/dev/null || git checkout master

  log "Finished processing issue #$ISSUE_NUM"
done

log "Coderabbit-fixer run complete"
