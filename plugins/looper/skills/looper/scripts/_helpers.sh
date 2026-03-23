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

# has_compose — Check if project uses docker-compose
# Usage: has_compose [stack_json]
has_compose() {
    local stack="${1:-$(load_stack)}"
    [ "$(echo "$stack" | jq -r '.has_compose // false')" = "true" ]
}

# compose_cmd — Return the docker compose command with override files
# Usage: cmd=$(compose_cmd); $cmd up -d
compose_cmd() {
    local compose_file=""
    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [ -f "$candidate" ]; then
            compose_file="$candidate"
            break
        fi
    done
    if [ -z "$compose_file" ]; then
        echo "docker compose"
        return
    fi
    if [ -f "docker-compose.looper.yml" ]; then
        echo "docker compose -f $compose_file -f docker-compose.looper.yml"
    else
        echo "docker compose -f $compose_file"
    fi
}

# load_compose_env — Source .env.looper if it exists, exporting all vars
load_compose_env() {
    if [ -f ".env.looper" ]; then
        set -a
        # shellcheck disable=SC1091
        source .env.looper
        set +a
    fi
}

# ensure_not_bare — Detect and fix core.bare=true on a git repo directory.
# Usage: ensure_not_bare [repo_dir]
# If repo_dir is omitted, uses the current git toplevel.
# Emits a warning to stderr when it fixes the issue.
#
# Strategy: UNSET core.bare entirely rather than setting it to false.
# When unset, git infers bare=false from the directory structure (.git dir +
# working tree). This is more robust than an explicit false because nothing
# can flip an inference — only an explicit config value can be overwritten.
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
        echo "[looper] WARNING: core.bare=true detected on $repo_dir — unsetting it now" >&2
        git -C "$repo_dir" config --unset core.bare
        echo "[looper] core.bare has been unset on $repo_dir (git will infer bare=false from working tree)" >&2
    fi
}
