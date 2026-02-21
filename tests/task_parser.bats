#!/usr/bin/env bats

setup() {
  export TEST_DIR
  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/.ralph"
  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] first task
2. [x] done task
EOF
  source "$BATS_TEST_DIRNAME/../scripts/task-parser.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "mark_task_complete updates the requested checkbox line" {
  run mark_task_complete "$TEST_DIR" "line_2"
  [ "$status" -eq 0 ]
  run grep -n "1. \[x\] first task" "$TEST_DIR/RALPH_TASK.md"
  [ "$status" -eq 0 ]
}

@test "mark_task_complete fails for invalid task id" {
  run mark_task_complete "$TEST_DIR" "bad_id"
  [ "$status" -ne 0 ]
}

@test "get_all_tasks preserves escaped quotes and backslashes" {
  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] escape "quote" and path C:\tmp\file.txt
EOF

  run get_all_tasks "$TEST_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'line_2|pending|escape "quote" and path C:\tmp\file.txt'* ]]
}

@test "get_task_model returns model annotation for a task" {
  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] parser work <!-- model: sonnet-4.6-thinking -->
2. [ ] no model task
EOF

  run get_task_model "$TEST_DIR" "line_2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sonnet-4.6-thinking"* ]]

  run get_task_model "$TEST_DIR" "line_3"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "get_task_model trims model annotation whitespace" {
  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] parser work <!-- model:   sonnet-4.6-thinking   -->
EOF

  run get_task_model "$TEST_DIR" "line_2"
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet-4.6-thinking" ]
}

@test "get_all_tasks_with_group includes model field" {
  cat > "$TEST_DIR/RALPH_TASK.md" <<'EOF'
# Task
1. [ ] parser work <!-- group: 1 --> <!-- model: sonnet-4.6-thinking -->
2. [ ] no model task <!-- group: 2 -->
EOF

  run get_all_tasks_with_group "$TEST_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"line_2|pending|1|sonnet-4.6-thinking|parser work"* ]]
  [[ "$output" == *"line_3|pending|2||no model task"* ]]
}
