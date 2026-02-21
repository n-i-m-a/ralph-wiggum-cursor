#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../scripts/ralph-retry.sh"
}

@test "with_retry accepts explicit jitter flag parsing" {
  run with_retry 1 1 60 false bash -c 'exit 0'
  [ "$status" -eq 0 ]
}

@test "with_retry keeps command position when max_delay omitted" {
  run with_retry 1 1 true bash -c 'exit 0'
  [ "$status" -eq 0 ]
}
