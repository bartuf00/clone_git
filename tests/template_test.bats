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

@test "apostrophes in valid branch names are escaped as YAML data" {
  run "$SCRIPT" --dry-run "$TEST_ROOT/workspace" https://github.com/upstream/project.git '0 4 * * *' ff-only main "feature/it's"

  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET_BRANCH: 'feature/it''s'"* ]]
}

@test "GitHub expressions cannot be embedded in rendered inputs" {
  run "$SCRIPT" --dry-run "$TEST_ROOT/workspace" 'https://example.test/${{ secrets.PAT_TOKEN }}' '0 4 * * *' ff-only

  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/workspace" ]
}

@test "invalid schedules are rejected before installation" {
  for cron in 'not a cron' '61 4 * * *' '0 24 * * *' '0 4 0 * *' '0 4 * 13 *' '0 4 * * 8' '*/0 * * * *'; do
    run "$SCRIPT" "$TEST_ROOT/workspace" https://github.com/upstream/project.git "$cron" ff-only
    [ "$status" -ne 0 ]
    [ ! -e "$TEST_ROOT/workspace" ]
  done
}

@test "invalid branch refs are rejected before installation" {
  run "$SCRIPT" "$TEST_ROOT/workspace" https://github.com/upstream/project.git '0 4 * * *' ff-only main '../bad'

  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/workspace" ]
}

@test "installation copies the sync runtime beside the workflow" {
  run "$SCRIPT" "$TEST_ROOT/workspace" https://github.com/upstream/project.git '17 3 * * 1' merge

  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/workspace/.github/workflows/upstream-sync.yml" ]
  cmp "$BATS_TEST_DIRNAME/../scripts/sync-upstream.sh" "$TEST_ROOT/workspace/.github/refork/sync-upstream.sh"
}
