# Agent harness: issue or change -> verified, ready-for-review PR

`issue-to-pr.sh` takes either a GitHub issue number or a plain-text change description and, unattended, produces a pushed branch and an open pull request that has already passed the project's own checks. No human input is required to get to an open, verified PR.

```
scripts/agent-harness/issue-to-pr.sh <issue-number> [options]
scripts/agent-harness/issue-to-pr.sh --change "description" [options]
```

## Convention: this is also how the harness itself gets changed

Changes to `scripts/agent-harness/*` must go through a PR like any other change -- never a direct commit to the base branch. Use `--change` for that:

```bash
scripts/agent-harness/issue-to-pr.sh --change "add a --dry-run alias for --no-pr" --type chore
```

This isn't a suggestion bolted on after the fact: an earlier version of this harness was itself added directly to `main` with no PR, which is exactly the shortcut this convention exists to prevent going forward.

## Pipeline

1. **Fetch** the issue (title/body/url) via `gh issue view` from `--issue-repo` (default `excalidraw/excalidraw`), or use the description passed via `--change`.
2. **Isolate**: create a fresh `git worktree` on a new branch (`agent/issue-<n>` or `agent/change-<slug>`) off `--base` (default `main`). The main working tree is never touched.
3. **Implement**: run a headless Claude Code agent (`claude -p`) inside that worktree with a scoped tool grant (`Bash Edit Write Read Grep Glob` -- not a blanket permission bypass) to investigate the root cause and implement a fix. The agent is told to self-check against `verify.sh` but is explicitly instructed **not** to push or open a PR itself.
4. **Independently verify**: the harness re-runs `scripts/agent-harness/verify.sh` (typecheck + lint + full test suite) itself. The agent's own claim that it's done is never the pass/fail signal -- only the harness's own rerun is.
5. **Retry on failure**: if verification fails, the failure output is fed back into the _same_ agent session (`claude -p -c`, so it keeps its prior context) and it gets another attempt, up to `--max-attempts` (default 2).
6. **Ship**: once verification passes, the harness commits any remaining changes, pushes the branch, and opens a PR against `--target-repo` (default: this repo's `origin` remote) via `gh pr create`, with a conventional-commit title (`--type`, default `fix` for issues / `chore` for `--change`) and scope inferred from which top-level path actually changed. If verification never passes, the script exits non-zero and does **not** open a PR -- the logs are preserved for a human to inspect.
7. **Report the PR's actual fate.** Opening a PR is not treated as "done": under `--auto-merge` the harness waits for the target repo's own CI (which independent verification in step 4 doesn't cover -- PR title lint, coverage thresholds, branch protection, etc.) and squash-merges once it's green; without `--auto-merge` (the default), or if CI fails/times out/merge is rejected, the harness says so explicitly (`AWAITING HUMAN REVIEW: ...`) instead of implying success just because a PR exists.

`verify.sh` is a small standalone script (typecheck + lint + `vitest run`) used by both the agent (while iterating) and the harness (as the actual gate), so there's exactly one definition of "green" that both sides agree on.

## Usage

```bash
# Fix issue #9281 from excalidraw/excalidraw, open a PR on this repo's origin fork
scripts/agent-harness/issue-to-pr.sh 9281

# Same, but wait for CI and squash-merge once green (otherwise: open PR, human reviews)
scripts/agent-harness/issue-to-pr.sh 9281 --auto-merge

# Dry run: implement + verify, but don't push or open a PR
scripts/agent-harness/issue-to-pr.sh 9281 --no-pr

# A harness/scaffolding change instead of a tracked issue
scripts/agent-harness/issue-to-pr.sh --change "description of the change" --type chore

# Point at different repos / base branch / retry budget
scripts/agent-harness/issue-to-pr.sh 9281 \
  --issue-repo excalidraw/excalidraw \
  --target-repo yourname/your-fork \
  --base main \
  --max-attempts 3
```

Logs (prompts sent to the agent, the agent's raw JSON output, and each verification run's output) are kept under `<workdir>/logs/`; the workdir is a fresh `mktemp -d` per run unless overridden with `--workdir`, and is printed at the start of the run. On failure the worktree itself is also kept (not cleaned up) so the state can be inspected.

## Requirements

- `git`, `gh` (authenticated with `repo` scope), `claude` (Claude Code CLI), `yarn`/`node`, `jq`.
- The Claude Code session/environment invoking this script needs permission to run it non-interactively (it shells out to `claude -p` with a scoped `--allowedTools` grant). If you're driving this from inside another Claude Code session with Auto Mode's safety classifier enabled, that classifier may block spawning a tool-granted nested agent by default; add an explicit allow rule for this script to `.claude/settings.json`, e.g.:

  ```json
  {
    "permissions": {
      "allow": ["Bash(bash scripts/agent-harness/issue-to-pr.sh:*)"]
    }
  }
  ```

## Design notes / known limitations

- **Least privilege over convenience**: the agent gets a scoped tool list, not `--dangerously-skip-permissions` / `bypassPermissions`. It can still run arbitrary shell commands via `Bash`, but the _tool surface_ is limited to what a code fix needs.
- **The harness, not the agent, gates the PR.** This is deliberate: an agent's self-report of "tests pass" is not trustworthy on its own.
- **Opening a PR is not the finish line.** A verified fix sitting on an open, unmerged PR indefinitely isn't a finished job either -- see step 7. `--auto-merge` is opt-in, not the default, since merging is normally a human decision; when it's off (or CI doesn't cooperate), the harness says so explicitly rather than letting "PR opened" read as "done".
- **Full test suite as the final gate.** For a large monorepo this can be slow; `verify.sh --fast` (typecheck + lint only) is available for quick iteration but the harness's own gate always runs the full suite.
- **Single retry loop, not a general auto-fix loop.** `--max-attempts` bounds cost; if a fix is fundamentally hard, this harness will fail closed (no PR) rather than loop indefinitely.
- **`node_modules` is symlinked, not reinstalled**, from the main repo checkout into the worktree, to avoid a slow/flaky `yarn install` per run. If the fix needs a dependency change, this assumption breaks and `yarn install` should be run manually in the worktree first.
