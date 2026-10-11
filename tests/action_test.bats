#!/usr/bin/env bats

setup() {
  TEST_ROOT=$(mktemp -d)
  export TEST_ROOT GIT_MASTER=1
  ACTION_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export ACTION_ROOT
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/caller" "$TEST_ROOT/runner"
  git init -q -b main "$TEST_ROOT/upstream"
  git -C "$TEST_ROOT/upstream" config user.name 'Bats Test'
  git -C "$TEST_ROOT/upstream" config user.email 'bats@example.test'
  printf 'base\n' >"$TEST_ROOT/upstream/file.txt"
  git -C "$TEST_ROOT/upstream" add file.txt
  git -C "$TEST_ROOT/upstream" commit -qm base
  git -C "$TEST_ROOT/upstream" tag original
  git -C "$TEST_ROOT/upstream" branch feature
  export GIT_CONFIG_GLOBAL="$TEST_ROOT/gitconfig"
  printf '[url "%s/upstream"]\n insteadOf = https://github.com/upstream/project.git\n[url "%s/target.git"]\n insteadOf = https://github.com/target/mirror.git\n' "$TEST_ROOT" "$TEST_ROOT" >"$GIT_CONFIG_GLOBAL"
  cat >"$TEST_ROOT/bin/gh" <<'EOF'
#!/bin/sh
set -eu
printf '%s | repo=%s\n' "$*" "${GH_REPO:-}" >>"$TEST_ROOT/gh.log"
case "$1 $2" in
  'repo create') git init -q --bare -b main "$TEST_ROOT/target.git" ;;
  'repo edit') : ;;
  'release view') exit 1 ;;
  'release create') [ "$GH_REPO" = target/mirror ] ;;
  *) printf 'Unexpected gh command: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/gh"
  export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_action() {
  python3 -c '
import os
import re
import subprocess
import yaml
inputs = {
    "source_repo_url": "upstream/project", "target_repo": "target/mirror",
    "visibility": "private", "sync_cron": "17 4 * * *", "sync_strategy": "merge",
    "upstream_branch": "main", "target_branch": "release",
    "release_tag": "v1$(>INJECTED)", "release_asset_path": "", "token": "test-token",
}
root = os.environ["TEST_ROOT"]
env = os.environ | {"GITHUB_WORKSPACE": root + "/caller", "RUNNER_TEMP": root + "/runner", "GITHUB_OUTPUT": root + "/outputs"}
values = {"github.action_path": os.environ["ACTION_ROOT"]}
values.update({"inputs." + key: value for key, value in inputs.items()})
with open(os.environ["ACTION_ROOT"] + "/action.yml", encoding="utf-8") as source:
    action = yaml.safe_load(source)
for step in action["runs"]["steps"]:
    step_env = env | {key: re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", lambda match: values[match[1]], str(value)) for key, value in step.get("env", {}).items()}
    script = re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", lambda match: values[match[1]], step["run"])
    subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script], cwd=root + "/caller", env=step_env, check=True)
'
}

@test "composite installs and publishes to the target without modifying the caller" {
  run run_action

  [ "$status" -eq 0 ]
  git --git-dir="$TEST_ROOT/target.git" show release:.github/workflows/upstream-sync.yml
  git --git-dir="$TEST_ROOT/target.git" show release:.github/refork/sync-upstream.sh
  [ "$(git --git-dir="$TEST_ROOT/target.git" rev-parse original)" = "$(git -C "$TEST_ROOT/upstream" rev-parse original)" ]
  [ "$(git --git-dir="$TEST_ROOT/target.git" rev-parse feature)" = "$(git -C "$TEST_ROOT/upstream" rev-parse feature)" ]
  [ ! -e "$TEST_ROOT/caller/.github" ]
  [ ! -e "$TEST_ROOT/caller/INJECTED" ]
  grep -q 'release create.*--target release.*repo=target/mirror' "$TEST_ROOT/gh.log"
  grep -q 'target_repo_url=https://github.com/target/mirror' "$TEST_ROOT/outputs"
}
