#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s [--dry-run] TARGET_DIR UPSTREAM_URL CRON STRATEGY [UPSTREAM_BRANCH [TARGET_BRANCH]]\n' "${0##*/}" >&2
}

escape_sed() {
    printf '%s' "$1" | sed "s/'/''/g" | sed 's/[\\&|]/\\&/g'
}

validate_cron() {
    printf '%s\n' "$1" | awk '
      function value(s, low, high, names, i, list) {
        split(names, list, ",")
        for (i in list) if (toupper(s) == list[i]) return i + low - 1
        if (s !~ /^[0-9]+$/ || s + 0 < low || s + 0 > high) return -1
        return s + 0
      }
      function field(s, low, high, names, n, parts, i, step, range, a, b, count) {
        n = split(s, parts, ",")
        for (i = 1; i <= n; i++) {
          count = split(parts[i], step, "/")
          if (count > 2 || (count == 2 && (step[2] !~ /^[0-9]+$/ || step[2] + 0 < 1))) return 0
          if (step[1] == "*") continue
          count = split(step[1], range, "-")
          if (count > 2) return 0
          a = value(range[1], low, high, names)
          b = count == 2 ? value(range[2], low, high, names) : a
          if (a < 0 || b < a) return 0
        }
        return 1
      }
      NF != 5 { exit 1 }
      !field($1, 0, 59, "") || !field($2, 0, 23, "") ||
      !field($3, 1, 31, "") || !field($4, 1, 12, "JAN,FEB,MAR,APR,MAY,JUN,JUL,AUG,SEP,OCT,NOV,DEC") ||
      !field($5, 0, 6, "SUN,MON,TUE,WED,THU,FRI,SAT") { exit 1 }
      END { if (NR != 1) exit 1 }
    '
}

main() {
    if [ "${1:-}" = "--help" ]; then usage; return; fi
    dry_run=0
    if [ "${1:-}" = "--dry-run" ]; then dry_run=1; shift; fi
    [ "$#" -ge 4 ] && [ "$#" -le 6 ] || { usage; exit 2; }
    target_dir=$1
    upstream_url=$2
    cron=$3
    strategy=$4
    upstream_branch=${5:-${UPSTREAM_BRANCH:-main}}
    target_branch=${6:-${TARGET_BRANCH:-main}}
    template_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../templates" && pwd)
    template=$template_dir/upstream-sync.yml.tmpl
    [ -f "$template" ] || { printf 'Template not found: %s\n' "$template" >&2; exit 1; }
    case "$strategy" in ff-only|merge|rebase) : ;; *) printf 'Invalid STRATEGY: %s\n' "$strategy" >&2; exit 2 ;; esac
    for input in "$upstream_url" "$cron" "$upstream_branch" "$target_branch"; do
        case "$input" in
            ''|*\$\{\{*|*'
'*|*"$(printf '\r')"*) printf 'Inputs must be nonempty single-line values without GitHub expressions.\n' >&2; exit 2 ;;
        esac
    done
    validate_cron "$cron" || { printf 'Invalid five-field CRON: %s\n' "$cron" >&2; exit 2; }
    git check-ref-format --branch "$upstream_branch" >/dev/null
    git check-ref-format --branch "$target_branch" >/dev/null
    case "$upstream_url" in
        git@github.com:*) upstream_url="https://github.com/${upstream_url#git@github.com:}" ;;
        ssh://git@github.com/*) upstream_url="https://github.com/${upstream_url#ssh://git@github.com/}" ;;
        */*) case "$upstream_url" in *:*|/*) : ;; *) upstream_url="https://github.com/${upstream_url%.git}.git" ;; esac ;;
    esac
    upstream_url=$(escape_sed "$upstream_url")
    cron=$(escape_sed "$cron")
    strategy=$(escape_sed "$strategy")
    upstream_branch=$(escape_sed "$upstream_branch")
    target_branch=$(escape_sed "$target_branch")
    rendered=$(mktemp)
    cleanup() { rm -f "$rendered"; }
    trap cleanup EXIT HUP INT TERM
    sed -e "s|__UPSTREAM_URL__|$upstream_url|g" -e "s|__CRON__|$cron|g" -e "s|__STRATEGY__|$strategy|g" -e "s|__UPSTREAM_BRANCH__|$upstream_branch|g" -e "s|__TARGET_BRANCH__|$target_branch|g" "$template" >"$rendered"
    if [ "$dry_run" -eq 1 ]; then
        cat "$rendered"
    else
        mkdir -p "$target_dir/.github/workflows"
        cp "$rendered" "$target_dir/.github/workflows/upstream-sync.yml"
        mkdir -p "$target_dir/.github/refork"
        cp "$template_dir/../scripts/sync-upstream.sh" "$target_dir/.github/refork/sync-upstream.sh"
        cp "$template_dir/../scripts/lfs_archive.py" "$target_dir/.github/refork/lfs_archive.py"
    fi
}

if [ "${0##*/}" = "install-sync-workflow.sh" ]; then
    main "$@"
fi
