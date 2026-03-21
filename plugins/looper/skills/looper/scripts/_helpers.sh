#!/usr/bin/env bash
# shellcheck disable=SC2154
# _helpers.sh — Shared helpers for looper run-* scripts
# This file is sourced, not executed directly.
# Requires: SCRIPT_DIR and package_manager must be set before sourcing.

# run_pkg_script — Run a package.json script via the detected package manager
# Uses $package_manager from the caller's scope.
run_pkg_script() {
    local script="$1"
    shift
    case "$package_manager" in
        pnpm) pnpm run "$script" -- "$@" ;;
        yarn) yarn run "$script" "$@" ;;
        bun)  bun run "$script" "$@" ;;
        npm|*) npm run "$script" -- "$@" ;;
    esac
}

# has_pkg_script — Check if package.json has a given script
has_pkg_script() {
    local script="$1"
    [ -f "package.json" ] && jq -e ".scripts.${script}" package.json &>/dev/null
}

# run_python_tool — Run a Python tool via uv/poetry/python -m
# Uses $package_manager from the caller's scope.
run_python_tool() {
    local tool="$1"
    shift
    case "$package_manager" in
        uv)     uv run "$tool" "$@" ;;
        poetry) poetry run "$tool" "$@" ;;
        *)      python -m "$tool" "$@" ;;
    esac
}

# load_stack — Load detect-stack JSON, with optional STACK_JSON caching
# If STACK_JSON env var is set, returns it directly; otherwise calls detect-stack.
load_stack() {
    if [ -n "${STACK_JSON:-}" ]; then
        echo "$STACK_JSON"
    else
        "$SCRIPT_DIR/detect-stack"
    fi
}

# ensure_not_bare — Detect and fix core.bare=true on a git repo directory.
# Usage: ensure_not_bare [repo_dir]
# If repo_dir is omitted, uses the current git toplevel.
# Emits a warning to stderr when it fixes the issue.
ensure_not_bare() {
    local repo_dir="${1:-}"
    if [ -z "$repo_dir" ]; then
        repo_dir=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    fi
    if [ -z "$repo_dir" ]; then
        return 0
    fi
    local bare_val
    bare_val=$(git -C "$repo_dir" config --get core.bare 2>/dev/null || echo "")
    if [ "$bare_val" = "true" ]; then
        echo "[looper] WARNING: core.bare=true detected on $repo_dir — fixing it now" >&2
        git -C "$repo_dir" config core.bare false
        echo "[looper] core.bare has been reset to false on $repo_dir" >&2
    fi
}
