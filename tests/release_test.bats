#!/usr/bin/env bats

setup() {
  TEST_ROOT=$(mktemp -d)
  BIN="$TEST_ROOT/bin"
  mkdir -p "$BIN"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/release-asset.sh"
  printf 'asset contents\n' >"$TEST_ROOT/asset.txt"
  cat >"$BIN/gh" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "release view") exit 0 ;;
  "release download")
    [ "${GH_MODE:-identical}" != missing ] || exit 1
    dir=$7
    cp "$GH_REMOTE" "$dir/asset.txt"
    ;;
  "release upload") printf 'uploaded\n' ;;
esac
EOF
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH" GH_LOG="$TEST_ROOT/gh.log" GH_REMOTE="$TEST_ROOT/remote.txt"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "identical downloaded asset is skipped" {
  cp "$TEST_ROOT/asset.txt" "$GH_REMOTE"

  run "$SCRIPT" v1 "$TEST_ROOT/asset.txt"

  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP asset.txt (identical)"* ]]
  ! grep -q 'release upload' "$GH_LOG"
}

@test "different downloaded asset is clobbered" {
  printf 'different\n' >"$GH_REMOTE"

  run "$SCRIPT" v1 "$TEST_ROOT/asset.txt"

  [ "$status" -eq 0 ]
  [[ "$output" != *"SKIP"* ]]
  grep -q 'release upload --clobber v1' "$GH_LOG"
}

@test "missing downloaded asset is uploaded" {
  run env GH_MODE=missing "$SCRIPT" v1 "$TEST_ROOT/asset.txt"

  [ "$status" -eq 0 ]
  [[ "$output" != *"SKIP"* ]]
  grep -q 'release download v1' "$GH_LOG"
  grep -q 'release upload --clobber v1' "$GH_LOG"
}
