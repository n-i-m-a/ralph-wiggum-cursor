#!/usr/bin/env bats

@test "ralph-loop supports --review-model flag and env var docs" {
  run rg --fixed-strings -- '--review-model MODEL' "$BATS_TEST_DIRNAME/../scripts/ralph-loop.sh"
  [ "$status" -eq 0 ]
  run rg 'RALPH_REVIEW_MODEL' "$BATS_TEST_DIRNAME/../scripts/ralph-loop.sh"
  [ "$status" -eq 0 ]
}

@test "ralph-once supports --review-model flag" {
  run rg --fixed-strings -- '--review-model MODEL' "$BATS_TEST_DIRNAME/../scripts/ralph-once.sh"
  [ "$status" -eq 0 ]
  run rg --fixed-strings -- '--review-model)' "$BATS_TEST_DIRNAME/../scripts/ralph-once.sh"
  [ "$status" -eq 0 ]
}

@test "ralph-setup exposes Enable review model option" {
  run rg --fixed-strings -- '"Enable review model"' "$BATS_TEST_DIRNAME/../scripts/ralph-setup.sh"
  [ "$status" -eq 0 ]
}
