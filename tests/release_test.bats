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
  "release view") [ "${GH_RELEASE:-existing}" != missing ] ;;
  "release download")
    [ "${GH_MODE:-identical}" != missing ] || exit 1
    shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pattern) pattern=$2; shift 2 ;;
        --dir) dir=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    asset_name=${GH_ASSET_NAME:-asset.txt}
    case "$asset_name" in $pattern) cp "$GH_REMOTE" "$dir/$asset_name" ;; *) exit 1 ;; esac
    ;;
  "release upload") printf 'uploaded\n' ;;
esac
EOF
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH" GH_LOG="$TEST_ROOT/gh.log" GH_REMOTE="$TEST_ROOT/remote.txt"
}

@test "a release tag can be published without an asset" {
  run env GH_RELEASE=missing TARGET_BRANCH=release "$SCRIPT" v1 ''

  [ "$status" -eq 0 ]
  grep -q 'release create v1.*--target release' "$GH_LOG"
  ! grep -q 'release upload' "$GH_LOG"
}

@test "release creation is noninteractive and respects the selected branch" {
  run env GH_RELEASE=missing GH_MODE=missing TARGET_BRANCH=release "$SCRIPT" v1 "$TEST_ROOT/asset.txt"

  [ "$status" -eq 0 ]
  grep -q 'release create v1.*--target release.*--notes' "$GH_LOG"
}

@test "literal bracket characters in asset names do not force a reupload" {
  asset_name='asset[1].txt'
  cp "$TEST_ROOT/asset.txt" "$TEST_ROOT/$asset_name"
  cp "$TEST_ROOT/asset.txt" "$GH_REMOTE"

  run env GH_ASSET_NAME="$asset_name" "$SCRIPT" v1 "$TEST_ROOT/$asset_name"

  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP $asset_name (identical)"* ]]
  ! grep -q 'release upload' "$GH_LOG"
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
