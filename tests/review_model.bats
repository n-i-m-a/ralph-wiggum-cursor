#!/usr/bin/env bats

setup() {
  export TEST_DIR
  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/.ralph"
  mkdir -p "$TEST_DIR/bin"

  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] first task
EOF

  git -C "$TEST_DIR" init >/dev/null 2>&1
  git -C "$TEST_DIR" config user.email "test@example.com"
  git -C "$TEST_DIR" config user.name "Test User"
  git -C "$TEST_DIR" add RALPH_TASK.md
  git -C "$TEST_DIR" commit -m "init task" >/dev/null 2>&1
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "build_prompt includes review.md in state files" {
  source "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  run build_prompt "$TEST_DIR" "1" "opus-4.6-thinking"
  [ "$status" -eq 0 ]
  [[ "$output" == *".ralph/review.md"* ]]
}

@test "run_review returns PASS and writes review file" {
  cat > "$TEST_DIR/bin/cursor-agent" <<'EOF'
#!/bin/bash
if [[ "$1" == "--list-models" ]]; then
  echo "opus-4.6-thinking - Claude 4.6 Opus (Thinking)"
  echo "sonnet-4.6-thinking - Claude 4.6 Sonnet (Thinking)"
  exit 0
fi
cat <<'JSON'
{"type":"assistant","message":{"content":[{"text":"<ralph>REVIEW_PASS</ralph>\n## Findings\nNo blocking issues.\n## Recommended next actions\n- None"}]}}
JSON
EOF
  chmod +x "$TEST_DIR/bin/cursor-agent"

  PATH="$TEST_DIR/bin:$PATH"
  source "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  REVIEW_MODEL="sonnet-4.6-thinking"

  run run_review "$TEST_DIR" "2" "opus-4.6-thinking"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  run grep -n "REVIEW_PASS" "$TEST_DIR/.ralph/review.md"
  [ "$status" -eq 0 ]
}

@test "run_review returns FAIL on malformed model output" {
  cat > "$TEST_DIR/bin/cursor-agent" <<'EOF'
#!/bin/bash
if [[ "$1" == "--list-models" ]]; then
  echo "opus-4.6-thinking - Claude 4.6 Opus (Thinking)"
  echo "sonnet-4.6-thinking - Claude 4.6 Sonnet (Thinking)"
  exit 0
fi
echo "this is not json output"
EOF
  chmod +x "$TEST_DIR/bin/cursor-agent"

  PATH="$TEST_DIR/bin:$PATH"
  source "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  REVIEW_MODEL="sonnet-4.6-thinking"

  run run_review "$TEST_DIR" "3" "opus-4.6-thinking"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"* ]]
  run grep -n "REVIEW_FAIL" "$TEST_DIR/.ralph/review.md"
  [ "$status" -eq 0 ]
}

@test "check_prerequisites rejects invalid review model" {
  cat > "$TEST_DIR/bin/cursor-agent" <<'EOF'
#!/bin/bash
if [[ "$1" == "--list-models" ]]; then
  echo "opus-4.6-thinking - Claude 4.6 Opus (Thinking)"
  echo "sonnet-4.6-thinking - Claude 4.6 Sonnet (Thinking)"
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/cursor-agent"

  PATH="$TEST_DIR/bin:$PATH"
  RALPH_MODEL="opus-4.6-thinking"
  source "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  REVIEW_MODEL="missing-review-model"

  run check_prerequisites "$TEST_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Review model"* ]]
}
