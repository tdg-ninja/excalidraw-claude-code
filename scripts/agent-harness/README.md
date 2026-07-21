# Agent harness: GitHub issue -> verified, ready-for-review PR

`issue-to-pr.sh` takes a GitHub issue number and, unattended, produces a
pushed branch and an open pull request that has already passed the
project's own checks. No human input is required until the PR itself is
reviewed.

```
scripts/agent-harness/issue-to-pr.sh <issue-number> [options]
```

## Pipeline

1. **Fetch** the issue (title/body/url) via `gh issue view` from
   `--issue-repo` (default `excalidraw/excalidraw`, since that's where this
   repo's public issues live).
2. **Isolate**: create a fresh `git worktree` on a new branch
   (`agent/issue-<n>`) off `--base` (default `main`). The main working tree
   is never touched.
3. **Implement**: run a headless Claude Code agent (`claude -p`) inside
   that worktree with a scoped tool grant (`Bash Edit Write Read Grep
   Glob` -- not a blanket permission bypass) to investigate the root
   cause and implement a fix. The agent is told to self-check against
   `verify.sh` but is explicitly instructed **not** to push or open a PR
   itself.
4. **Independently verify**: the harness re-runs
   `scripts/agent-harness/verify.sh` (typecheck + lint + full test suite)
   itself. The agent's own claim that it's done is never the pass/fail
   signal -- only the harness's own rerun is.
5. **Retry on failure**: if verification fails, the failure output is fed
   back into the *same* agent session (`claude -p -c`, so it keeps its
   prior context) and it gets another attempt, up to `--max-attempts`
   (default 2).
6. **Ship**: once verification passes, the harness commits any remaining
   changes, pushes the branch, and opens a PR against `--target-repo`
   (default: this repo's `origin` remote) via `gh pr create`. If
   verification never passes, the script exits non-zero and does **not**
   open a PR -- the logs are preserved for a human to inspect.

`verify.sh` is a small standalone script (typecheck + lint + `vitest run`)
used by both the agent (while iterating) and the harness (as the actual
gate), so there's exactly one definition of "green" that both sides agree
on.

## Usage

```bash
# Fix issue #9281 from excalidraw/excalidraw, open a PR on this repo's origin fork
scripts/agent-harness/issue-to-pr.sh 9281

# Dry run: implement + verify, but don't push or open a PR
scripts/agent-harness/issue-to-pr.sh 9281 --no-pr

# Point at different repos / base branch / retry budget
scripts/agent-harness/issue-to-pr.sh 9281 \
  --issue-repo excalidraw/excalidraw \
  --target-repo yourname/your-fork \
  --base main \
  --max-attempts 3
```

Logs (prompts sent to the agent, the agent's raw JSON output, and each
verification run's output) are kept under `<workdir>/logs/`; the workdir
is a fresh `mktemp -d` per run unless overridden with `--workdir`, and is
printed at the start of the run. On failure the worktree itself is also
kept (not cleaned up) so the state can be inspected.

## Requirements

- `git`, `gh` (authenticated with `repo` scope), `claude` (Claude Code
  CLI), `yarn`/`node`, `jq`.
- The Claude Code session/environment invoking this script needs
  permission to run it non-interactively (it shells out to `claude -p`
  with a scoped `--allowedTools` grant). If you're driving this from
  inside another Claude Code session with Auto Mode's safety classifier
  enabled, that classifier may block spawning a tool-granted nested
  agent by default; add an explicit allow rule for this script to
  `.claude/settings.json`, e.g.:

  ```json
  {
    "permissions": {
      "allow": ["Bash(bash scripts/agent-harness/issue-to-pr.sh:*)"]
    }
  }
  ```

## Design notes / known limitations

- **Least privilege over convenience**: the agent gets a scoped tool
  list, not `--dangerously-skip-permissions` / `bypassPermissions`. It
  can still run arbitrary shell commands via `Bash`, but the *tool
  surface* is limited to what a code fix needs.
- **The harness, not the agent, gates the PR.** This is deliberate: an
  agent's self-report of "tests pass" is not trustworthy on its own.
- **Full test suite as the final gate.** For a large monorepo this can be
  slow; `verify.sh --fast` (typecheck + lint only) is available for quick
  iteration but the harness's own gate always runs the full suite.
- **Single retry loop, not a general auto-fix loop.** `--max-attempts`
  bounds cost; if a fix is fundamentally hard, this harness will fail
  closed (no PR) rather than loop indefinitely.
- **`node_modules` is symlinked, not reinstalled**, from the main repo
  checkout into the worktree, to avoid a slow/flaky `yarn install` per
  run. If the fix needs a dependency change, this assumption breaks and
  `yarn install` should be run manually in the worktree first.
