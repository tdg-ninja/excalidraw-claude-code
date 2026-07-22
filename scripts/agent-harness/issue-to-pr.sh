#!/usr/bin/env bash
#
# Autonomous "request -> verified, ready-for-review PR" harness.
#
# Usage:
#   scripts/agent-harness/issue-to-pr.sh <issue-number> [options]
#   scripts/agent-harness/issue-to-pr.sh --change "description" [options]
#
# Given either a GitHub issue number, or a plain-text description of a
# change (e.g. a fix to this harness itself), this drives an unattended
# Claude Code agent to investigate, implement, and verify it, then pushes
# a branch and opens a pull request. No human input is required to get to
# an open, verified PR.
#
# This is also how changes to this harness's own scripts should be made:
# never commit scaffolding changes directly to the base branch. Run
# `issue-to-pr.sh --change "..."` (or open a PR by hand) like any other
# change, so it goes through review too.
#
# Pipeline:
#   1. Fetch the issue (title/body/url) from --issue-repo, or use the
#      description passed via --change.
#   2. Create an isolated git worktree on a fresh branch off --base.
#   3. Run a headless Claude Code agent (`claude -p`) inside that worktree,
#      with a scoped tool grant, to investigate and implement a fix. The
#      agent is instructed to self-check with scripts/agent-harness/verify.sh
#      but is NOT trusted to push or open the PR itself.
#   4. Independently re-run verify.sh inside the harness -- the agent's
#      self-report is never the pass/fail signal, only the harness's own
#      rerun is.
#   5. If verification fails, feed the failure output back into the *same*
#      agent session (`claude -p -c`) and retry, up to --max-attempts.
#   6. On success: commit, push the branch, and open a PR against
#      --target-repo via `gh pr create`. On exhausted retries: exit
#      non-zero with the failure logs' location and do NOT open a PR.
#   7. Report the PR's fate in plain terms: merged (only under
#      --auto-merge, and only once the target repo's own CI actually
#      passes), or explicitly flagged as awaiting human review. Opening a
#      PR is not treated as "done" on its own -- a fix sitting on an open,
#      unmerged PR indefinitely is not a finished job.
#
# Options:
#   --change DESC             Plain-text change description, instead of an issue number
#                              (e.g. for changes to this harness itself)
#   --title TITLE             Short title for --change mode (default: DESC itself)
#   --type TYPE                Conventional-commit type for the PR title
#                              (default: "fix" for an issue, "chore" for --change)
#   --issue-repo OWNER/REPO   Repo the issue lives in (default: excalidraw/excalidraw)
#   --target-repo OWNER/REPO Repo to push the branch/PR to (default: origin remote)
#   --base BRANCH             Base branch to branch from / target for the PR (default: main)
#   --max-attempts N          Implement<->verify retry budget (default: 2)
#   --model MODEL             Passthrough to `claude --model`
#   --workdir DIR             Parent dir for the worktree + logs (default: mktemp -d)
#   --keep-worktree           Don't remove the worktree on exit (for debugging)
#   --no-pr                   Do everything except push + open the PR (dry run)
#   --auto-merge              After opening the PR, wait for the target repo's own
#                              CI and squash-merge it once green. Without this flag
#                              (the default) the PR is left open for human review.
#   --max-merge-wait SECONDS Bound on how long --auto-merge waits for CI (default: 900)
#
# Requires: git, gh (authenticated, repo scope), claude (Claude Code CLI),
# yarn/node.

set -uo pipefail

# ---------- argument parsing ----------

ISSUE_NUMBER=""
CHANGE_DESC=""
CHANGE_TITLE=""
TYPE=""
ISSUE_REPO="excalidraw/excalidraw"
TARGET_REPO=""
BASE_BRANCH="main"
MAX_ATTEMPTS=2
MODEL=""
WORKDIR=""
KEEP_WORKTREE=0
NO_PR=0
AUTO_MERGE=0
MAX_MERGE_WAIT=900

print_help() {
  awk 'NR==1{next} /^set -uo pipefail/{exit} {sub(/^# ?/,""); print}' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --change) CHANGE_DESC="$2"; shift 2 ;;
    --title) CHANGE_TITLE="$2"; shift 2 ;;
    --type) TYPE="$2"; shift 2 ;;
    --issue-repo) ISSUE_REPO="$2"; shift 2 ;;
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --base) BASE_BRANCH="$2"; shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --keep-worktree) KEEP_WORKTREE=1; shift ;;
    --no-pr) NO_PR=1; shift ;;
    --auto-merge) AUTO_MERGE=1; shift ;;
    --max-merge-wait) MAX_MERGE_WAIT="$2"; shift 2 ;;
    -h|--help) print_help; exit 0 ;;
    *)
      if [ -z "$ISSUE_NUMBER" ]; then
        ISSUE_NUMBER="$1"; shift
      else
        echo "Unknown argument: $1" >&2; exit 2
      fi
      ;;
  esac
done

if [ -n "$ISSUE_NUMBER" ] && [ -n "$CHANGE_DESC" ]; then
  echo "pass either an issue number or --change, not both" >&2
  exit 2
fi
if [ -z "$ISSUE_NUMBER" ] && [ -z "$CHANGE_DESC" ]; then
  echo "usage: $0 <issue-number> [options]" >&2
  echo "       $0 --change \"description\" [options]" >&2
  exit 2
fi
if [ -z "$TYPE" ]; then
  if [ -n "$ISSUE_NUMBER" ]; then TYPE="fix"; else TYPE="chore"; fi
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

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-50
}

if [ -n "$ISSUE_NUMBER" ]; then
  BRANCH="agent/issue-${ISSUE_NUMBER}"
  WORKDIR_SLUG="issue-${ISSUE_NUMBER}"
else
  BRANCH="agent/change-$(slugify "${CHANGE_TITLE:-$CHANGE_DESC}")"
  WORKDIR_SLUG="change-$(slugify "${CHANGE_TITLE:-$CHANGE_DESC}")"
fi

if [ -z "$WORKDIR" ]; then
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-harness-${WORKDIR_SLUG}.XXXXXX")"
fi

LOG_DIR="$WORKDIR/logs"
mkdir -p "$LOG_DIR"
WORKTREE_DIR="$WORKDIR/worktree"

log() { printf '[issue-to-pr] %s\n' "$*"; }

if [ -n "$ISSUE_NUMBER" ]; then
  log "issue:        ${ISSUE_REPO}#${ISSUE_NUMBER}"
else
  log "change:       ${CHANGE_TITLE:-$CHANGE_DESC}"
fi
log "target repo:  ${TARGET_REPO}"
log "base branch:  ${BASE_BRANCH}"
log "branch:       ${BRANCH}"
log "workdir:      ${WORKDIR}"

# ---------- 1. fetch the issue, or use the provided change description ----------

if [ -n "$ISSUE_NUMBER" ]; then
  log "fetching issue..."
  issue_json="$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json number,title,body,url)"
  ISSUE_TITLE="$(printf '%s' "$issue_json" | jq -r '.title')"
  ISSUE_BODY="$(printf '%s' "$issue_json" | jq -r '.body')"
  ISSUE_URL="$(printf '%s' "$issue_json" | jq -r '.url')"
  log "title: ${ISSUE_TITLE}"
else
  ISSUE_TITLE="${CHANGE_TITLE:-$CHANGE_DESC}"
  ISSUE_BODY="$CHANGE_DESC"
  ISSUE_URL=""
fi

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
You are operating unattended as part of an automated request-to-PR pipeline.
Nobody will read your intermediate output or answer questions -- work
autonomously to completion.

Your job:
1. Investigate the root cause of the bug, or understand the scope of the
   change, described below in this codebase.
2. Implement the minimal, correct fix or change. Follow existing code
   conventions.
3. Add or update a regression test covering it, if one can reasonably be
   added given the existing test setup for this area of the code.
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
  if [ -n "$ISSUE_NUMBER" ]; then
    printf '\n\n## Issue %s#%s: %s\n\nURL: %s\n\n### Issue body\n\n%s\n' \
      "$ISSUE_REPO" "$ISSUE_NUMBER" "$ISSUE_TITLE" "$ISSUE_URL" "$ISSUE_BODY"
  else
    printf '\n\n## Requested change: %s\n\n### Description\n\n%s\n' \
      "$ISSUE_TITLE" "$ISSUE_BODY"
  fi
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

if [ -n "$ISSUE_URL" ]; then
  REFERENCE_LINE="Fixes ${ISSUE_URL}"
else
  REFERENCE_LINE="Implements the requested change (no tracked issue)."
fi

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "$(printf '%s\n\n%s\n\nAutonomously implemented and verified by scripts/agent-harness/issue-to-pr.sh.' "$ISSUE_TITLE" "$REFERENCE_LINE")" --quiet
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
PR_TITLE="${TYPE}(${PR_SCOPE}): ${ISSUE_TITLE}"

PR_BODY=$(printf '%s\n\n%s\n\n---\n\nOpened autonomously by the `scripts/agent-harness/issue-to-pr.sh` agent harness: investigate -> implement -> independently re-verify (typecheck + lint + full test suite) -> PR. Verification log: `%s`.' \
  "$REFERENCE_LINE" "$ISSUE_TITLE" "verify-attempt-${attempt}.log")

pr_url="$(gh pr create \
  --repo "$TARGET_REPO" \
  --head "$BRANCH" \
  --base "$BASE_BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY")"

log "PR opened: $pr_url"

# ---------- 7. merge, or clearly flag as awaiting human review ----------
#
# Independent verification (step 4) only re-runs this repo's own
# checks/tests; it says nothing about the target repo's CI (semantic PR
# title, coverage thresholds, branch protection, etc.), and a fix sitting
# on an open, unmerged PR indefinitely is not "done". This harness never
# treats "PR opened" as the finish line: it either merges under
# --auto-merge (only once the target repo's own CI actually goes green),
# or says so explicitly.

if [ "$AUTO_MERGE" -ne 1 ]; then
  log "AWAITING HUMAN REVIEW: --auto-merge not requested. PR opened but NOT merged: $pr_url"
  echo "$pr_url"
  exit 0
fi

log "waiting up to ${MAX_MERGE_WAIT}s for ${TARGET_REPO}'s CI to settle before auto-merging..."
waited=0
ci_result="timeout"
while [ "$waited" -lt "$MAX_MERGE_WAIT" ]; do
  rollup="$(gh pr view "$pr_url" --json statusCheckRollup -q '[.statusCheckRollup[]?.conclusion // "PENDING"] | join(",")' 2>/dev/null || echo "")"
  if [ -z "$rollup" ]; then
    ci_result="none"
    break
  fi
  if ! printf '%s' "$rollup" | grep -qi 'PENDING\|null'; then
    if printf '%s' "$rollup" | grep -qiE 'FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED'; then
      ci_result="failed"
    else
      ci_result="passed"
    fi
    break
  fi
  sleep 15
  waited=$((waited + 15))
done

case "$ci_result" in
  passed|none)
    if gh pr merge "$pr_url" --squash --delete-branch; then
      log "MERGED: $pr_url"
    else
      log "AWAITING HUMAN REVIEW: CI passed but 'gh pr merge' failed (e.g. branch protection) for $pr_url. A human must merge it."
    fi
    ;;
  failed)
    log "AWAITING HUMAN REVIEW: ${TARGET_REPO}'s CI failed on $pr_url. Not auto-merging -- a human must review and fix or merge it."
    ;;
  timeout)
    log "AWAITING HUMAN REVIEW: CI did not settle within ${MAX_MERGE_WAIT}s on $pr_url. Not auto-merging -- a human must check it."
    ;;
esac

echo "$pr_url"
