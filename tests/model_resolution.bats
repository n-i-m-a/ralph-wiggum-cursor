#!/usr/bin/env bats

setup() {
  export TEST_DIR
  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/.ralph"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "resolve_model prefers step annotation over global model" {
  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] first task <!-- model: sonnet-4.6-thinking -->
2. [ ] second task
EOF

  RALPH_MODEL="gpt-5.3-codex-high"
  source "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"

  run resolve_model "$TEST_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet-4.6-thinking" ]
}

@test "resolve_model falls back to global model when no step annotation exists" {
  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] first task
2. [ ] second task
EOF

  RALPH_MODEL="gpt-5.3-codex-high"
  source "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"

  run resolve_model "$TEST_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.3-codex-high" ]
}

@test "resolve_model falls back to global model when step model is unavailable" {
  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] first task <!-- model: unknown-model -->
EOF

  RALPH_MODEL="gpt-5.3-codex-high"
  source "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  RALPH_MODEL_LIST_CACHE=$'gpt-5.3-codex-high - Global model\nopus-4.6-thinking - Reasoning model'

  run resolve_model "$TEST_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gpt-5.3-codex-high"* ]]
}
