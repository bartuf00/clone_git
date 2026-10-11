#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s [--dry-run] TARGET_DIR UPSTREAM_URL CRON STRATEGY [UPSTREAM_BRANCH [TARGET_BRANCH]]\n' "${0##*/}" >&2
    exit 2
}

escape_sed() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

main() {
    dry_run=0
    if [ "${1:-}" = "--dry-run" ]; then dry_run=1; shift; fi
    [ "$#" -ge 4 ] && [ "$#" -le 6 ] || usage
    target_dir=$1
    upstream_url=$2
    cron=$3
    strategy=$4
    upstream_branch=${5:-${UPSTREAM_BRANCH:-main}}
    target_branch=${6:-${TARGET_BRANCH:-main}}
    template_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../templates" && pwd)
    template=$template_dir/upstream-sync.yml.tmpl
    [ -f "$template" ] || { printf 'Template not found: %s\n' "$template" >&2; exit 1; }
    case "$strategy" in ff-only|merge|rebase) : ;; *) printf 'Invalid STRATEGY: %s\n' "$strategy" >&2; exit 2 ;; esac
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
    fi
}

if [ "${0##*/}" = "install-sync-workflow.sh" ]; then
    main "$@"
fi
