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

@test "normalizes the short owner/repo source form to HTTPS" {
  run "$SCRIPT" --dry-run upstream/project "target/mirror"

  [ "$status" -eq 0 ]
  [[ "$output" == *"git clone --bare https://github.com/upstream/project.git"* ]]
}

@test "rejects malformed source and target repository names" {
  for repo in 'a/b/c' 'a//b' '/b' 'a/' '-a/b' 'a/b?x' 'a/b c'; do
    run "$SCRIPT" --dry-run "$repo" target/mirror
    [ "$status" -ne 0 ]
    run "$SCRIPT" --dry-run upstream/project "$repo"
    [ "$status" -ne 0 ]
  done
}

@test "accepts the documented GitHub SSH URL form" {
  run "$SCRIPT" --dry-run git@github.com:upstream/project.git target/mirror

  [ "$status" -eq 0 ]
  [[ "$output" == *"git clone --bare https://github.com/upstream/project.git"* ]]
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
