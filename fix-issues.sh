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
git pull origin main --ff-only
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
  git pull origin main --ff-only

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
  CLAUDE_ERR=$(mktemp)
  timeout "$CLAUDE_TIMEOUT" cat "$PROMPT_FILE" | claude --dangerously-skip-permissions -p >> "$LOG_FILE" 2>"$CLAUDE_ERR" || CLAUDE_EXIT=$?
  rm -f "$PROMPT_FILE"

  if [ "$CLAUDE_EXIT" -ne 0 ]; then
    log "Claude failed or timed out for issue #$ISSUE_NUM (exit code: $CLAUDE_EXIT). Will retry next cycle."
    log "Claude stderr: $(cat "$CLAUDE_ERR")"
    rm -f "$CLAUDE_ERR"
    git checkout main 2>/dev/null || git checkout master
    git branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi
  rm -f "$CLAUDE_ERR"

  # Check if Claude made any changes
  if git diff --quiet && git diff --cached --quiet; then
    log "No changes made for issue #$ISSUE_NUM. Will retry next cycle."
    git checkout main 2>/dev/null || git checkout master
    git branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi

  # Self-review, commit, push, and PR — all handled by Claude
  log "Running self-review, commit, push, and PR creation for issue #$ISSUE_NUM..."
  REVIEW_PROMPT_FILE=$(mktemp)
  cat > "$REVIEW_PROMPT_FILE" <<REVIEW_EOF
You just made changes to fix issue #$ISSUE_NUM. Now do the following steps in order:

1. REVIEW: Run "coderabbit --prompt-only --type uncommitted" to review your changes.
   Read the output and fix any issues it finds. Do not revert the original fix — only improve it.
   After fixing, run pnpm lint:fix and pnpm typecheck again.

2. COMMIT: Stage all changes with git add, then commit with message:
   "fix: $ISSUE_TITLE (#$ISSUE_NUM)"
   Let the pre-commit hooks run. If they fail, fix the issues and try committing again.

3. PUSH: Push the branch to origin with: git push origin $BRANCH --force-with-lease

4. CREATE PR: Create a draft PR using:
   gh pr create --repo $REPO --draft --title "fix: $ISSUE_TITLE (#$ISSUE_NUM)" --body "Closes #$ISSUE_NUM

$(echo "$ISSUE_BODY" | head -20)

---
Automated by coderabbit-fixer"

Print the PR URL at the end.
REVIEW_EOF

  REVIEW_EXIT=0
  CLAUDE_ERR=$(mktemp)
  timeout "$CLAUDE_TIMEOUT" cat "$REVIEW_PROMPT_FILE" | claude --dangerously-skip-permissions -p >> "$LOG_FILE" 2>"$CLAUDE_ERR" || REVIEW_EXIT=$?
  rm -f "$REVIEW_PROMPT_FILE"

  if [ "$REVIEW_EXIT" -ne 0 ]; then
    log "Review/commit/push failed for issue #$ISSUE_NUM (exit code: $REVIEW_EXIT)."
    log "Claude stderr: $(cat "$CLAUDE_ERR")"
    rm -f "$CLAUDE_ERR"
    git checkout main 2>/dev/null || git checkout master
    git branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi
  rm -f "$CLAUDE_ERR"

  log "Completed issue #$ISSUE_NUM"

  # Mark issue as processed
  echo "$ISSUE_NUM" >> "$STATE_FILE"

  # Return to main
  git checkout main 2>/dev/null || git checkout master

  log "Finished processing issue #$ISSUE_NUM"
done

log "Coderabbit-fixer run complete"
