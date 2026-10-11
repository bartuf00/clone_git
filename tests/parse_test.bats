#!/usr/bin/env bats

setup() {
  TEST_ROOT=$(mktemp -d)
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/create-mirror.sh"
  export PAT_TOKEN=test-token
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "parses an HTTPS GitHub URL and defaults visibility to private" {
  run "$SCRIPT" --dry-run https://github.com/upstream/project.git "target/mirror"

  [ "$status" -eq 0 ]
  [[ "$output" == *"+ gh repo create target/mirror --private"* ]]
  [[ "$output" == *"git clone --bare https://github.com/upstream/project.git"* ]]
}

@test "passes through the short owner/repo source form" {
  run "$SCRIPT" --dry-run upstream/project "target/mirror"

  [ "$status" -eq 0 ]
  [[ "$output" == *"git clone --bare upstream/project"* ]]
}

@test "rejects an invalid source URL" {
  run "$SCRIPT" --dry-run not-a-repository "target/mirror"

  [ "$status" -ne 0 ]
  [[ "$output" == *"SOURCE_URL must be a GitHub HTTPS URL or owner/repo"* ]]
}

@test "accepts public visibility when requested" {
  run env VISIBILITY=public "$SCRIPT" --dry-run upstream/project "target/mirror"

  [ "$status" -eq 0 ]
  [[ "$output" == *"+ gh repo create target/mirror --public"* ]]
}
