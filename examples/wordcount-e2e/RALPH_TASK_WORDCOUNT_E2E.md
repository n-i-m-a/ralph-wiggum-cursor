---
task: Build a POSIX shell word-count wrapper that outputs JSON
test_command: "bash test.sh"
completion_criteria:
  - wc-wrap.sh accepts a file path and outputs JSON
  - Missing file returns error JSON and exit code 1
  - test.sh passes all assertions
max_iterations: 5
---

# Task: JSON Word Count Wrapper

## Overview

Create a shell script that wraps the `wc` command and outputs structured JSON.

## Requirements

1. `wc-wrap.sh <file>` outputs: `{"lines":N,"words":N,"chars":N,"file":"<file>"}`
2. If the file does not exist, output: `{"error":"file not found","file":"<file>"}` and exit 1
3. `test.sh` exercises both the happy path and the error path

## Success Criteria

1. [ ] `wc-wrap.sh` exists, is executable, and outputs valid JSON for a real file
2. [ ] `wc-wrap.sh` returns error JSON and exit 1 for a missing file
3. [ ] `bash test.sh` exits 0 (all assertions pass)

---

## Ralph Instructions

1. Read `.ralph/progress.md` to see what's been done
2. Check `.ralph/guardrails.md` for signs to follow
3. Work on the next incomplete criterion
4. Update `.ralph/progress.md` with your progress
5. Commit your changes with descriptive messages
6. When ALL criteria are met, output: `<ralph>COMPLETE</ralph>`
7. If stuck on the same issue 3+ times, output: `<ralph>GUTTER</ralph>`
