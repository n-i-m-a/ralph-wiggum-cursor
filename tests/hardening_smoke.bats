#!/usr/bin/env bats

@test "run_iteration no longer uses eval for cursor-agent invocation" {
  run rg 'eval\s+"\$cmd' "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  [ "$status" -ne 0 ]
}

@test "stream-parser thresholds are env-configurable" {
  run rg 'WARN_THRESHOLD="\$\{WARN_THRESHOLD:-70000\}"' "$BATS_TEST_DIRNAME/../scripts/stream-parser.sh"
  [ "$status" -eq 0 ]
  run rg 'ROTATE_THRESHOLD="\$\{ROTATE_THRESHOLD:-80000\}"' "$BATS_TEST_DIRNAME/../scripts/stream-parser.sh"
  [ "$status" -eq 0 ]
}

@test "run_ralph_loop integrates optional review model gate" {
  run rg 'if \[\[ -n "\$REVIEW_MODEL" \]\]; then' "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  [ "$status" -eq 0 ]
  run rg 'Review failed\. Feedback written to \.ralph/review\.md' "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  [ "$status" -eq 0 ]
}

@test "check_prerequisites validates review model id" {
  run rg "Review model '\\\$REVIEW_MODEL' not found" "$BATS_TEST_DIRNAME/../scripts/ralph-common.sh"
  [ "$status" -eq 0 ]
}
