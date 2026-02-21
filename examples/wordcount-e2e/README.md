# E2E Example: JSON Word Count Wrapper

Minimal Ralph task to validate the full loop (task parsing, iteration, criteria, completion) without a heavy build. Uses a POSIX shell script only; no npm/TypeScript.

## Task file

- **Source:** `RALPH_TASK_WORDCOUNT_E2E.md` (copy as `RALPH_TASK.md` into a fresh repo)

## How to run

1. **Create a fresh git-initialized directory and add the task:**

   ```bash
   mkdir -p /tmp/ralph-test && cd /tmp/ralph-test
   cp /path/to/ralph/examples/wordcount-e2e/RALPH_TASK_WORDCOUNT_E2E.md RALPH_TASK.md
   git init && git add RALPH_TASK.md && git commit -m "init: add RALPH_TASK.md for wordcount e2e"
   ```

2. **Install Ralph into that directory** (if not already):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/n-i-m-a/ralph-wiggum-cursor/main/install.sh | bash
   ```

   Or point at your fork. Then use the scripts from the **ralph repo** for once/loop (see below).

3. **Single iteration (recommended first):**

   ```bash
   /path/to/ralph/scripts/ralph-once.sh /tmp/ralph-test
   ```

   Requires `cursor-agent` CLI. If missing, Ralph will exit with install instructions.

4. **Full loop (after one successful “once” run):**

   ```bash
   /path/to/ralph/scripts/ralph-loop.sh -n 5 -y /tmp/ralph-test
   ```

5. **Full loop with review model (optional):**

   ```bash
   /path/to/ralph/scripts/ralph-loop.sh -n 5 -y --review-model sonnet-4.6-thinking /tmp/ralph-test
   ```

## What to verify after a successful run

- **Git:** `git -C /tmp/ralph-test log --oneline` — agent commits (e.g. `ralph: implement wc-wrap.sh`).
- **Artifacts:** `wc-wrap.sh`, `test.sh` in the workspace.
- **Tests:** `bash /tmp/ralph-test/test.sh` — exits 0.
- **State:** `.ralph/progress.md`, `.ralph/activity.log` updated; all criteria in `RALPH_TASK.md` checked `[x]`.
- **Review mode (if enabled):** `.ralph/review.md` exists and contains either `<ralph>REVIEW_PASS</ralph>` or `<ralph>REVIEW_FAIL</ralph>`.
- **Review fail behavior:** if review fails, loop continues and next iteration consumes `.ralph/review.md`.

## What this exercises

Task parser, stream-parser token tracking, `check_task_complete`, prompt build, iteration/loop, optional review-model pass, completion detection, git integration, `.ralph/` state.
