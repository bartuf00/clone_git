#!/usr/bin/env bats

setup() {
  TEST_ROOT=$(mktemp -d)
  UPSTREAM="$TEST_ROOT/upstream.git"
  ORIGIN="$TEST_ROOT/origin.git"
  TARGET="$TEST_ROOT/target"
  git init --bare "$UPSTREAM" >/dev/null
  git init --bare "$ORIGIN" >/dev/null
  git init -b main "$TARGET" >/dev/null
  git -C "$TARGET" config user.name 'Bats Test'
  git -C "$TARGET" config user.email 'bats@example.test'
  printf 'base\n' >"$TARGET/file.txt"
  git -C "$TARGET" add file.txt
  git -C "$TARGET" commit -m base >/dev/null
  git -C "$TARGET" remote add origin "$ORIGIN"
  git -C "$TARGET" remote add upstream "$UPSTREAM"
  git -C "$TARGET" push origin main >/dev/null
  git -C "$TARGET" push upstream main >/dev/null
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/sync-upstream.sh"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

add_upstream_commit() {
  git clone -q "$UPSTREAM" "$TEST_ROOT/upstream-work"
  git -C "$TEST_ROOT/upstream-work" checkout -q main
  git -C "$TEST_ROOT/upstream-work" config user.name 'Bats Test'
  git -C "$TEST_ROOT/upstream-work" config user.email 'bats@example.test'
  printf '%s\n' "$1" >"$TEST_ROOT/upstream-work/file.txt"
  git -C "$TEST_ROOT/upstream-work" add file.txt
  git -C "$TEST_ROOT/upstream-work" commit -m update >/dev/null
  git -C "$TEST_ROOT/upstream-work" push -q origin main
}

run_sync() {
  (cd "$TARGET" && env DRY_RUN=1 "$SCRIPT" "$@")
}

@test "ff-only synchronizes when the target is an ancestor" {
  add_upstream_commit upstream

  run run_sync "$UPSTREAM" main main ff-only

  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY_RUN=1: skipping push to main"* ]]
  [ "$(git -C "$TARGET" rev-parse HEAD)" = "$(git --git-dir="$UPSTREAM" rev-parse main)" ]
}

@test "identical SHAs exit successfully without merging" {
  sha=$(git -C "$TARGET" rev-parse HEAD)

  run run_sync "$UPSTREAM" main main ff-only

  [ "$status" -eq 0 ]
  [[ "$output" == *"Already synchronized at $sha"* ]]
}

@test "ff-only fails safely on divergent histories" {
  add_upstream_commit upstream
  printf 'local\n' >>"$TARGET/file.txt"
  git -C "$TARGET" add file.txt
  git -C "$TARGET" commit -m local >/dev/null
  local_sha=$(git -C "$TARGET" rev-parse HEAD)

  run run_sync "$UPSTREAM" main main ff-only

  [ "$status" -ne 0 ]
  [ "$(git -C "$TARGET" rev-parse HEAD)" = "$local_sha" ]
  [ ! -f "$TARGET/.git/MERGE_HEAD" ]
}

@test "merge conflict returns nonzero and aborts the merge" {
  add_upstream_commit upstream
  printf 'local\n' >"$TARGET/file.txt"
  git -C "$TARGET" add file.txt
  git -C "$TARGET" commit -m local >/dev/null

  run run_sync "$UPSTREAM" main main merge

  [ "$status" -ne 0 ]
  [ ! -f "$TARGET/.git/MERGE_HEAD" ]
  [ -z "$(git -C "$TARGET" status --porcelain | grep '^UU' || true)" ]
}

@test "rebase conflict returns nonzero and aborts the rebase" {
  add_upstream_commit upstream
  printf 'local\n' >"$TARGET/file.txt"
  git -C "$TARGET" add file.txt
  git -C "$TARGET" commit -m local >/dev/null

  run run_sync "$UPSTREAM" main main rebase

  [ "$status" -ne 0 ]
  [ ! -d "$TARGET/.git/rebase-merge" ]
  [ ! -d "$TARGET/.git/rebase-apply" ]
}

@test "synchronizes the requested branch without modifying another checkout" {
  add_upstream_commit upstream
  git -C "$TARGET" checkout -b feature
  printf 'feature\n' >"$TARGET/feature.txt"
  git -C "$TARGET" add feature.txt
  git -C "$TARGET" commit -m feature
  feature_sha=$(git -C "$TARGET" rev-parse HEAD)

  run run_sync "$UPSTREAM" main main ff-only

  [ "$status" -eq 0 ]
  [ "$(git -C "$TARGET" rev-parse feature)" = "$feature_sha" ]
  [ "$(git -C "$TARGET" rev-parse main)" = "$(git --git-dir="$UPSTREAM" rev-parse main)" ]
}

@test "creates a local checkout for an existing remote target branch" {
  git -C "$TARGET" push origin main:release
  add_upstream_commit upstream

  run run_sync "$UPSTREAM" main release ff-only

  [ "$status" -eq 0 ]
  [ "$(git -C "$TARGET" rev-parse release)" = "$(git --git-dir="$UPSTREAM" rev-parse main)" ]
}

@test "rebase publishes rewritten target history with a lease" {
  printf 'local\n' >"$TARGET/local.txt"
  git -C "$TARGET" add local.txt
  git -C "$TARGET" commit -m local
  git -C "$TARGET" push origin main
  old_sha=$(git -C "$TARGET" rev-parse HEAD)
  add_upstream_commit upstream

  run bash -c 'cd "$1" && "$2" "$3" main main rebase' _ "$TARGET" "$SCRIPT" "$UPSTREAM"

  [ "$status" -eq 0 ]
  new_sha=$(git --git-dir="$ORIGIN" rev-parse main)
  [ "$new_sha" != "$old_sha" ]
  [ "$(git -C "$TARGET" rev-parse HEAD)" = "$new_sha" ]
  git -C "$TARGET" merge-base --is-ancestor "$(git --git-dir="$UPSTREAM" rev-parse main)" HEAD
}

@test "dirty worktrees are rejected without changing local files" {
  add_upstream_commit upstream
  printf 'dirty\n' >"$TARGET/untracked.txt"
  old_sha=$(git -C "$TARGET" rev-parse HEAD)

  run run_sync "$UPSTREAM" main main ff-only

  [ "$status" -ne 0 ]
  [ "$(git -C "$TARGET" rev-parse HEAD)" = "$old_sha" ]
  [ "$(cat "$TARGET/untracked.txt")" = dirty ]
}
