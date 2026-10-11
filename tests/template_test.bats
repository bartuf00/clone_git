#!/usr/bin/env bats

setup() {
  TEST_ROOT=$(mktemp -d)
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/install-sync-workflow.sh"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "dry-run renders the cron, upstream URL, and strategy" {
  run "$SCRIPT" --dry-run "$TEST_ROOT/workspace" "https://example.test/upstream.git" "17 3 * * 1" rebase

  [ "$status" -eq 0 ]
  [[ "$output" == *"cron: '17 3 * * 1'"* ]]
  [[ "$output" == *"UPSTREAM_URL: 'https://example.test/upstream.git'"* ]]
  [[ "$output" == *"default: rebase"* ]]
  [[ "$output" != *"__CRON__"* ]]
  [[ "$output" != *"__UPSTREAM_URL__"* ]]
  [[ "$output" != *"__STRATEGY__"* ]]
}
