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
