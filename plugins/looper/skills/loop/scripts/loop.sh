#!/usr/bin/env bash
set -euo pipefail

# loop.sh — PDC Loop Orchestrator
# Runs Plan → Do → Check agents in a loop until PASS or max iterations.
# Agents are defined in agents/{planner,doer,checker}.md

# ──────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────
TASK_NAME=""
TASK_PROMPT=""
EXTRA_CONTEXT=""
MODEL="sonnet"
MAX_ITERATIONS=10
MAX_TURNS=50
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: loop.sh --task <name> --prompt <prompt> [options]

Required:
  --task            Sanitized task name (used as commit scope)
  --prompt          Task description / prompt for agents

Options:
  --context         Extra context (e.g., CI failure details)
  --model           Claude model to use (default: sonnet)
  --max-iterations  Max PDC iterations (default: 10)
  --max-turns       Max turns per agent phase (default: 50)
  -h, --help        Show this help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK_NAME="$2"; shift 2 ;;
        --prompt) TASK_PROMPT="$2"; shift 2 ;;
        --context) EXTRA_CONTEXT="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
        --max-turns) MAX_TURNS="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$TASK_NAME" ] || [ -z "$TASK_PROMPT" ]; then
    echo "Error: --task and --prompt are required." >&2
    usage
fi

# ──────────────────────────────────────────────
# Dependency checks
# ──────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in claude jq git; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: Missing required dependencies: ${missing[*]}" >&2
        exit 1
    fi
}
check_deps

# ──────────────────────────────────────────────
# Build project context (collected once, injected into every agent)
# ──────────────────────────────────────────────
build_project_context() {
    local ctx=""

    # Project docs that claude -p does NOT auto-inject
    for file in CONTRIBUTING.md AGENTS.md README.md \
                .github/PULL_REQUEST_TEMPLATE.md .editorconfig; do
        if [ -f "$file" ]; then
            ctx+="
---
## File: ${file}

$(cat "$file")
"
        fi
    done

    # Build/script config (extract relevant sections only)
    if [ -f "package.json" ]; then
        ctx+="
---
## Project scripts (from package.json)

$(node -e "const p=require('./package.json'); console.log(JSON.stringify(p.scripts||{},null,2))" 2>/dev/null || echo "{}")
"
    fi

    if [ -f "Makefile" ]; then
        ctx+="
---
## Makefile targets

$(grep -E '^[a-zA-Z_-]+:' Makefile | sed 's/:.*//')
"
    fi

    if [ -f "pyproject.toml" ]; then
        ctx+="
---
## Python project config (from pyproject.toml)

$(cat pyproject.toml)
"
    fi

    if [ -f "Cargo.toml" ]; then
        ctx+="
---
## Rust project config (from Cargo.toml)

$(cat Cargo.toml)
"
    fi

    echo "$ctx"
}

# ──────────────────────────────────────────────
# Build dynamic context file for a phase
# ──────────────────────────────────────────────
build_context_file() {
    local phase="$1"
    local context_file
    context_file=$(mktemp "/tmp/pdc-context-$$-${phase}.XXXXXX.md")

    # Get loop context from prior iterations
    local loop_context
    loop_context=$("$SCRIPTS_DIR/git-loop-context" \
        --task "$TASK_NAME" --iteration "$ITERATION" 2>/dev/null || echo "No prior context.")

    cat > "$context_file" <<CTX_EOF
<project-context>
${PROJECT_CONTEXT}
</project-context>

You MUST follow the conventions and instructions in <project-context>.
Pay special attention to CONTRIBUTING.md for build/test/lint/commit conventions.

---

## Task Variables

- **TASK_NAME:** ${TASK_NAME}
- **ITERATION:** ${ITERATION}
- **TASK_PROMPT:** ${TASK_PROMPT}
- **SCRIPTS_DIR:** ${SCRIPTS_DIR}

## Prior Loop Context

${loop_context}
CTX_EOF

    if [ -n "$EXTRA_CONTEXT" ]; then
        cat >> "$context_file" <<CTX_EXTRA

## Additional Context

${EXTRA_CONTEXT}
CTX_EXTRA
    fi

    echo "$context_file"
}

# ──────────────────────────────────────────────
# Run a single agent phase
# ──────────────────────────────────────────────
run_phase() {
    local phase="$1"
    local agent="$2"

    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  ${phase^^} PHASE — Iteration ${ITERATION}"
    echo "════════════════════════════════════════════════════════"
    echo ""

    # Build dynamic context file
    local context_file
    context_file=$(build_context_file "$phase")

    # Allow claude -p to launch when invoked from inside a Claude Code session
    unset CLAUDECODE

    # Run claude -p with --agent
    local exit_code=0
    claude -p \
        --agent "$agent" \
        --model "$MODEL" \
        --setting-sources user,project \
        --dangerously-skip-permissions \
        --max-turns "$MAX_TURNS" \
        --append-system-prompt-file "$context_file" \
        "You are the ${phase} agent for task '${TASK_NAME}', iteration ${ITERATION}. Execute your instructions." \
        || exit_code=$?

    # Cleanup temp file
    rm -f "$context_file"

    if [ $exit_code -ne 0 ]; then
        echo "Warning: ${phase} agent exited with code ${exit_code}" >&2
    fi

    return $exit_code
}

# ──────────────────────────────────────────────
# Detect resume point
# ──────────────────────────────────────────────
detect_resume_iteration() {
    local last_iteration
    last_iteration=$(git log --grep="Loop-Phase:" --grep="Loop-Iteration:" \
        --all-match --format="%B" -1 2>/dev/null \
        | grep -oP 'Loop-Iteration: \K[0-9]+' || echo "0")

    local last_verdict
    last_verdict=$(git log --grep="Loop-Verdict:" -1 --format="%B" 2>/dev/null \
        | grep -oP 'Loop-Verdict: \K(PASS|FAIL)' || echo "")

    if [ "$last_verdict" = "FAIL" ]; then
        echo $((last_iteration + 1))
    elif [ "$last_iteration" -gt 0 ] && [ -z "$last_verdict" ]; then
        # Mid-iteration — resume at same iteration
        echo "$last_iteration"
    else
        echo "1"
    fi
}

# ──────────────────────────────────────────────
# SIGINT trap — preserve state
# ──────────────────────────────────────────────
cleanup() {
    echo ""
    echo "Interrupted at iteration ${ITERATION:-?}. State preserved in git log."
    echo "Re-run the same command to resume."
    rm -f /tmp/pdc-context-$$-*.md
    exit 130
}
trap cleanup SIGINT SIGTERM

# ──────────────────────────────────────────────
# Main loop
# ──────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  PDC Loop — ${TASK_NAME}                                "
echo "║  Model: ${MODEL} | Max iterations: ${MAX_ITERATIONS}    "
echo "╚══════════════════════════════════════════════════════════╝"

# Collect project context once
PROJECT_CONTEXT=$(build_project_context)

# Detect where to start
START_ITERATION=$(detect_resume_iteration)
if [ "$START_ITERATION" -gt 1 ]; then
    echo ""
    echo "Resuming from iteration ${START_ITERATION} (prior iterations found in git log)"
fi

for (( ITERATION=START_ITERATION; ITERATION<=MAX_ITERATIONS; ITERATION++ )); do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ITERATION ${ITERATION} of ${MAX_ITERATIONS}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── PLAN PHASE ──
    run_phase "planner" "planner"

    # ── DO PHASE ──
    run_phase "doer" "doer"

    # ── CHECK PHASE ──
    run_phase "checker" "checker"

    # ── EVALUATE VERDICT ──
    VERDICT=$(git log --grep="Loop-Verdict:" -1 --format="%B" \
        | grep -oP 'Loop-Verdict: \K(PASS|FAIL)' || echo "")

    if [ "$VERDICT" = "PASS" ]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  PASS — Task complete after ${ITERATION} iteration(s)   "
        echo "╚══════════════════════════════════════════════════════════╝"
        exit 0
    elif [ "$VERDICT" = "FAIL" ]; then
        echo ""
        echo "FAIL — Iteration ${ITERATION}. Continuing to next iteration..."
    else
        echo ""
        echo "Warning: Could not parse verdict from checker. Treating as FAIL." >&2
    fi
done

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  FAIL — Max iterations (${MAX_ITERATIONS}) reached      "
echo "╚══════════════════════════════════════════════════════════╝"
exit 1
