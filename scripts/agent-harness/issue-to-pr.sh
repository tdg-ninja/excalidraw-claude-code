#!/usr/bin/env bash
#
# Autonomous "GitHub issue -> verified, ready-for-review PR" harness.
#
# Usage:
#   scripts/agent-harness/issue-to-pr.sh <issue-number> [options]
#
# Given a GitHub issue number, this drives an unattended Claude Code agent
# to investigate, plan, implement, and verify a fix, then pushes a branch
# and opens a pull request. No human input is required until the resulting
# PR is reviewed.
#
# Pipeline:
#   1. Fetch the issue (title/body/url) from --issue-repo.
#   2. Create an isolated git worktree on a fresh branch off --base.
#   3. Run a headless Claude Code agent (`claude -p`) inside that worktree,
#      with full tool access, to investigate and implement a fix. The agent
#      is instructed to self-check with scripts/agent-harness/verify.sh but
#      is NOT trusted to push or open the PR itself.
#   4. Independently re-run verify.sh inside the harness -- the agent's
#      self-report is never the pass/fail signal, only the harness's own
#      rerun is.
#   5. If verification fails, feed the failure output back into the *same*
#      agent session (`claude -p -c`) and retry, up to --max-attempts.
#   6. On success: commit, push the branch, and open a PR against
#      --target-repo via `gh pr create`. On exhausted retries: exit
#      non-zero with the failure logs' location and do NOT open a PR.
#
# Options:
#   --issue-repo OWNER/REPO   Repo the issue lives in (default: excalidraw/excalidraw)
#   --target-repo OWNER/REPO Repo to push the branch/PR to (default: origin remote)
#   --base BRANCH             Base branch to branch from / target for the PR (default: main)
#   --max-attempts N          Implement<->verify retry budget (default: 2)
#   --model MODEL             Passthrough to `claude --model`
#   --workdir DIR             Parent dir for the worktree + logs (default: mktemp -d)
#   --keep-worktree           Don't remove the worktree on exit (for debugging)
#   --no-pr                   Do everything except push + open the PR (dry run)
#
# Requires: git, gh (authenticated, repo scope), claude (Claude Code CLI),
# yarn/node.

set -uo pipefail

# ---------- argument parsing ----------

ISSUE_NUMBER=""
ISSUE_REPO="excalidraw/excalidraw"
TARGET_REPO=""
BASE_BRANCH="main"
MAX_ATTEMPTS=2
MODEL=""
WORKDIR=""
KEEP_WORKTREE=0
NO_PR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --issue-repo) ISSUE_REPO="$2"; shift 2 ;;
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --base) BASE_BRANCH="$2"; shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --keep-worktree) KEEP_WORKTREE=1; shift ;;
    --no-pr) NO_PR=1; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *)
      if [ -z "$ISSUE_NUMBER" ]; then
        ISSUE_NUMBER="$1"; shift
      else
        echo "Unknown argument: $1" >&2; exit 2
      fi
      ;;
  esac
done

if [ -z "$ISSUE_NUMBER" ]; then
  echo "usage: $0 <issue-number> [options]" >&2
  exit 2
fi

for bin in git gh claude yarn jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required dependency: $bin" >&2; exit 2; }
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [ -z "$TARGET_REPO" ]; then
  origin_url="$(git remote get-url origin)"
  TARGET_REPO="$(printf '%s' "$origin_url" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
fi

if [ -z "$WORKDIR" ]; then
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-harness-issue-${ISSUE_NUMBER}.XXXXXX")"
fi

LOG_DIR="$WORKDIR/logs"
mkdir -p "$LOG_DIR"
WORKTREE_DIR="$WORKDIR/worktree"
BRANCH="agent/issue-${ISSUE_NUMBER}"

log() { printf '[issue-to-pr] %s\n' "$*"; }

log "issue:        ${ISSUE_REPO}#${ISSUE_NUMBER}"
log "target repo:  ${TARGET_REPO}"
log "base branch:  ${BASE_BRANCH}"
log "branch:       ${BRANCH}"
log "workdir:      ${WORKDIR}"

# ---------- 1. fetch the issue ----------

log "fetching issue..."
issue_json="$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json number,title,body,url)"
ISSUE_TITLE="$(printf '%s' "$issue_json" | jq -r '.title')"
ISSUE_BODY="$(printf '%s' "$issue_json" | jq -r '.body')"
ISSUE_URL="$(printf '%s' "$issue_json" | jq -r '.url')"
log "title: ${ISSUE_TITLE}"

# ---------- 2. isolated worktree on a fresh branch ----------

git fetch origin "$BASE_BRANCH" --quiet || true
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git branch -D "$BRANCH" >/dev/null
fi
base_ref="origin/${BASE_BRANCH}"
git show-ref --verify --quiet "refs/remotes/${base_ref}" || base_ref="$BASE_BRANCH"

log "creating worktree at ${WORKTREE_DIR} (branch ${BRANCH} off ${base_ref})..."
git worktree add -b "$BRANCH" "$WORKTREE_DIR" "$base_ref" --quiet

cleanup() {
  if [ "$KEEP_WORKTREE" -eq 0 ]; then
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Reuse installed deps instead of a full reinstall in the fresh worktree.
if [ -d "$REPO_ROOT/node_modules" ]; then
  ln -s "$REPO_ROOT/node_modules" "$WORKTREE_DIR/node_modules"
else
  log "no node_modules in $REPO_ROOT, running yarn install in worktree..."
  (cd "$WORKTREE_DIR" && yarn install)
fi

# ---------- 3. headless coding agent ----------

# Scoped tool grant (least privilege) rather than a blanket permission
# bypass: only what's needed to investigate, edit, and self-verify.
AGENT_TOOLS="Bash Edit Write Read Grep Glob"

# Written straight to a file (not captured via $(...)) because bash 3.2
# (macOS's /bin/bash) mis-parses a quoted heredoc's embedded quote
# characters when the heredoc is nested inside a command substitution.
INSTR_FILE="$LOG_DIR/instructions.md"
cat > "$INSTR_FILE" <<'EOF'
You are operating unattended as part of an automated issue-to-PR pipeline.
Nobody will read your intermediate output or answer questions -- work
autonomously to completion.

Your job:
1. Investigate the root cause of the bug described below in this codebase.
2. Implement the minimal, correct fix. Follow existing code conventions.
3. Add or update a regression test covering the bug, if one can reasonably
   be added given the existing test setup for this area of the code.
4. Run `scripts/agent-harness/verify.sh` and iterate until it passes. This
   runs the project's typecheck, lint, and test suite -- it is the same
   gate that decides whether your work becomes a pull request, so do not
   consider the task done until it is green. Use `scripts/agent-harness/verify.sh --fast`
   (typecheck + lint only) while iterating quickly, but confirm with a
   full (non-fast) run before you finish.
5. Do NOT modify files unrelated to this fix.
6. Do NOT run `git push`, `git commit --amend` on existing history, or open
   a pull request yourself. Leave your fix as uncommitted (or committed,
   either is fine) changes in the working tree -- an outer harness handles
   committing, pushing, and opening the PR after independently re-verifying
   your work.
7. When you finish (or if you get stuck after genuinely trying), stop and
   summarize what you changed and why, and the exact verify.sh result.
EOF

PROMPT_FILE_1="$LOG_DIR/prompt-attempt-1.txt"
{
  cat "$INSTR_FILE"
  printf '\n\n## Issue %s#%s: %s\n\nURL: %s\n\n### Issue body\n\n%s\n' \
    "$ISSUE_REPO" "$ISSUE_NUMBER" "$ISSUE_TITLE" "$ISSUE_URL" "$ISSUE_BODY"
} > "$PROMPT_FILE_1"

log "launching headless coding agent (attempt 1/${MAX_ATTEMPTS})..."
(
  cd "$WORKTREE_DIR"
  claude -p \
    --allowedTools "$AGENT_TOOLS" \
    --output-format json \
    ${MODEL:+--model "$MODEL"} \
    < "$PROMPT_FILE_1"
) > "$LOG_DIR/agent-attempt-1.json" 2>&1
log "agent attempt 1 finished, log: $LOG_DIR/agent-attempt-1.json"

# ---------- 4/5. independent verify + retry loop ----------

attempt=1
verified=0
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  log "running independent verification (attempt ${attempt}/${MAX_ATTEMPTS})..."
  if ( cd "$WORKTREE_DIR" && bash scripts/agent-harness/verify.sh ) > "$LOG_DIR/verify-attempt-${attempt}.log" 2>&1; then
    log "verification PASSED (attempt ${attempt}). log: $LOG_DIR/verify-attempt-${attempt}.log"
    verified=1
    break
  fi
  log "verification FAILED (attempt ${attempt}). log: $LOG_DIR/verify-attempt-${attempt}.log"

  attempt=$((attempt + 1))
  if [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
    break
  fi

  log "feeding failures back into the same agent session (attempt ${attempt}/${MAX_ATTEMPTS})..."
  FOLLOWUP_FILE="$LOG_DIR/prompt-attempt-${attempt}.txt"
  {
    printf 'scripts/agent-harness/verify.sh failed. Fix the remaining issues, then rerun it until it passes. Do not push or open a PR. Output:\n\n'
    tail -c 8000 "$LOG_DIR/verify-attempt-$((attempt - 1)).log"
  } > "$FOLLOWUP_FILE"
  (
    cd "$WORKTREE_DIR"
    claude -p -c \
      --allowedTools "$AGENT_TOOLS" \
      --output-format json \
      ${MODEL:+--model "$MODEL"} \
      < "$FOLLOWUP_FILE"
  ) > "$LOG_DIR/agent-attempt-${attempt}.json" 2>&1
  log "agent attempt ${attempt} finished, log: $LOG_DIR/agent-attempt-${attempt}.json"
done

if [ "$verified" -ne 1 ]; then
  log "FAILED: verification did not pass after ${MAX_ATTEMPTS} attempt(s)."
  log "logs are preserved at: $LOG_DIR"
  KEEP_WORKTREE=1
  exit 1
fi

# ---------- 6. commit, push, open PR ----------

cd "$WORKTREE_DIR"

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "$(printf 'fix: %s\n\nFixes %s\n\nAutonomously implemented and verified by scripts/agent-harness/issue-to-pr.sh.' "$ISSUE_TITLE" "$ISSUE_URL")" --quiet
fi

if git rev-parse --verify "${base_ref}" >/dev/null 2>&1 && [ -z "$(git log "${base_ref}..HEAD" --oneline)" ]; then
  log "FAILED: agent produced no commits/changes."
  KEEP_WORKTREE=1
  exit 1
fi

if [ "$NO_PR" -eq 1 ]; then
  log "NO-PR mode: skipping push + PR. Verified fix is committed on local branch ${BRANCH} in ${WORKTREE_DIR}."
  KEEP_WORKTREE=1
  exit 0
fi

log "pushing ${BRANCH} to ${TARGET_REPO}..."
git push --force-with-lease -u origin "$BRANCH"

# excalidraw's semantic-pull-request check requires a conventional-commit
# scope (app, editor, packages/excalidraw, packages/utils, docker, repo).
# Infer it from where the fix actually landed rather than hardcoding one.
changed_files="$(git diff --name-only "${base_ref}..HEAD")"
if printf '%s\n' "$changed_files" | grep -q '^excalidraw-app/'; then
  PR_SCOPE="app"
elif printf '%s\n' "$changed_files" | grep -q '^packages/utils/'; then
  PR_SCOPE="packages/utils"
elif printf '%s\n' "$changed_files" | grep -q '^packages/excalidraw/'; then
  PR_SCOPE="editor"
elif printf '%s\n' "$changed_files" | grep -qE '(^|/)(Dockerfile|docker-compose\.ya?ml)$'; then
  PR_SCOPE="docker"
else
  PR_SCOPE="repo"
fi
PR_TITLE="fix(${PR_SCOPE}): ${ISSUE_TITLE}"

PR_BODY=$(printf 'Fixes %s\n\n%s\n\n---\n\nOpened autonomously by the `scripts/agent-harness/issue-to-pr.sh` agent harness: issue -> investigate -> implement -> independently re-verify (typecheck + lint + full test suite) -> PR, with no human in the loop. Verification log: `%s`.' \
  "$ISSUE_URL" "$ISSUE_TITLE" "verify-attempt-${attempt}.log")

pr_url="$(gh pr create \
  --repo "$TARGET_REPO" \
  --head "$BRANCH" \
  --base "$BASE_BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY")"

log "PR opened: $pr_url"
echo "$pr_url"
