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

VERBOSE=false
PHASE_TIMEOUT=""        # empty = no timeout
INTERACTIVE=false

# Metrics tracking
declare -a PHASE_TIMES_PLAN=()
declare -a PHASE_TIMES_DO=()
declare -a PHASE_TIMES_CHECK=()
TOTAL_TOKENS_IN=0
TOTAL_TOKENS_OUT=0
LOOP_START_SECONDS=$SECONDS
LAST_PHASE_DURATION=0

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
  --verbose         Enable detailed debug logging to stderr
  --timeout         Seconds per phase (wraps claude -p with timeout command)
  --interactive     Pause after each Checker phase for user confirmation
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
        --verbose) VERBOSE=true; shift ;;
        --timeout) PHASE_TIMEOUT="$2"; shift 2 ;;
        --interactive) INTERACTIVE=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$TASK_NAME" ] || [ -z "$TASK_PROMPT" ]; then
    echo "Error: --task and --prompt are required." >&2
    usage
fi

# ──────────────────────────────────────────────
# Dependency checks (after arg parsing so PHASE_TIMEOUT is available)
# ──────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in claude jq git; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ -n "$PHASE_TIMEOUT" ] && ! command -v timeout &>/dev/null; then
        missing+=("timeout")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: Missing required dependencies: ${missing[*]}" >&2
        exit 1
    fi
}
check_deps

# ──────────────────────────────────────────────
# Debug helper — writes to stderr only when --verbose
# ──────────────────────────────────────────────
debug() {
    if [ "$VERBOSE" = true ]; then
        echo "[DEBUG $(date +%T)] $*" >&2
    fi
}

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
# Parse token usage from a stderr capture file
# ──────────────────────────────────────────────
parse_tokens() {
    local file="$1"
    local phase="$2"
    [ -f "$file" ] || return 0

    local input_tok output_tok
    input_tok=$(grep -oE '"input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' "$file" \
        | grep -oE '[0-9]+$' | awk '{s+=$1} END{print s+0}')
    output_tok=$(grep -oE '"output_tokens"[[:space:]]*:[[:space:]]*[0-9]+' "$file" \
        | grep -oE '[0-9]+$' | awk '{s+=$1} END{print s+0}')

    TOTAL_TOKENS_IN=$(( TOTAL_TOKENS_IN + ${input_tok:-0} ))
    TOTAL_TOKENS_OUT=$(( TOTAL_TOKENS_OUT + ${output_tok:-0} ))

    debug "Tokens for ${phase} phase: in=${input_tok:-0}, out=${output_tok:-0}"
}

# ──────────────────────────────────────────────
# Print iteration metrics summary
# ──────────────────────────────────────────────
print_summary() {
    local final_verdict="${1:-UNKNOWN}"
    local total_time=$(( SECONDS - LOOP_START_SECONDS ))
    local num_iters=${#PHASE_TIMES_PLAN[@]}

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  LOOP SUMMARY                                            ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    printf "%-12s %-12s %-10s %-12s %-10s\n" \
        "Iteration" "Plan(s)" "Do(s)" "Check(s)" "Total(s)"
    printf '%s\n' "────────────────────────────────────────────────────────"

    for (( i=0; i<num_iters; i++ )); do
        local iter_total=$(( ${PHASE_TIMES_PLAN[$i]:-0} + ${PHASE_TIMES_DO[$i]:-0} + ${PHASE_TIMES_CHECK[$i]:-0} ))
        printf "%-12s %-12s %-10s %-12s %-10s\n" \
            "$((i+1))" \
            "${PHASE_TIMES_PLAN[$i]:-n/a}" \
            "${PHASE_TIMES_DO[$i]:-n/a}" \
            "${PHASE_TIMES_CHECK[$i]:-n/a}" \
            "$iter_total"
    done

    printf '%s\n' "────────────────────────────────────────────────────────"
    echo ""
    echo "Total wall-clock time : ${total_time}s"
    echo "Iterations completed  : ${num_iters}"
    echo "Final verdict         : ${final_verdict}"
    if [ "$TOTAL_TOKENS_IN" -gt 0 ] || [ "$TOTAL_TOKENS_OUT" -gt 0 ]; then
        echo ""
        echo "Token usage:"
        echo "  Input  : ${TOTAL_TOKENS_IN}"
        echo "  Output : ${TOTAL_TOKENS_OUT}"
        echo "  Total  : $(( TOTAL_TOKENS_IN + TOTAL_TOKENS_OUT ))"
    fi
    echo ""
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

    # Record start time
    local phase_start=$SECONDS

    debug "Starting ${phase} phase (agent=${agent}, model=${MODEL}, max-turns=${MAX_TURNS})"

    # Build dynamic context file
    local context_file
    context_file=$(build_context_file "$phase")

    # Allow claude -p to launch when invoked from inside a Claude Code session.
    # All Claude-related env vars must be cleared to avoid recursion guards.
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS 2>/dev/null || true

    # Build command as array
    local claude_cmd=(claude -p
        --agent "$agent"
        --model "$MODEL"
        --setting-sources user,project
        --dangerously-skip-permissions
        --max-turns "$MAX_TURNS"
        --append-system-prompt-file "$context_file"
        "You are the ${phase} agent for task '${TASK_NAME}', iteration ${ITERATION}. Execute your instructions.")

    debug "Command: ${claude_cmd[*]}"

    # Temp file for stderr capture
    local stderr_file
    stderr_file=$(mktemp "/tmp/pdc-stderr-$$-${phase}.XXXXXX")

    # Run command, capturing stderr for token parsing; stdout streams live
    local exit_code=0
    if [ -n "$PHASE_TIMEOUT" ]; then
        debug "Applying timeout: ${PHASE_TIMEOUT}s"
        timeout "$PHASE_TIMEOUT" "${claude_cmd[@]}" 2>"$stderr_file" || exit_code=$?
    else
        "${claude_cmd[@]}" 2>"$stderr_file" || exit_code=$?
    fi

    # Forward captured stderr to terminal
    cat "$stderr_file" >&2

    # Record timing
    LAST_PHASE_DURATION=$(( SECONDS - phase_start ))
    debug "Phase ${phase} completed in ${LAST_PHASE_DURATION}s, exit code ${exit_code}"

    # Parse token usage
    parse_tokens "$stderr_file" "$phase"

    # Cleanup temp files
    rm -f "$stderr_file" "$context_file"

    if [ $exit_code -ne 0 ]; then
        if [ -n "$PHASE_TIMEOUT" ] && [ $exit_code -eq 124 ]; then
            echo "Warning: ${phase} agent timed out after ${PHASE_TIMEOUT}s" >&2
        else
            echo "Warning: ${phase} agent exited with code ${exit_code}" >&2
        fi
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
        | sed -n 's/^Loop-Iteration: \([0-9]*\)$/\1/p' | head -1)
    last_iteration="${last_iteration:-0}"

    local last_verdict
    last_verdict=$(git log --grep="Loop-Verdict:" --grep="Loop-Iteration: ${last_iteration}" \
        --all-match --format="%B" -1 2>/dev/null \
        | sed -n 's/^Loop-Verdict: \(PASS\|FAIL\)$/\1/p' | head -1)
    last_verdict="${last_verdict:-}"

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
# SIGINT trap — preserve state and print summary
# ──────────────────────────────────────────────
cleanup() {
    echo ""
    echo "Interrupted at iteration ${ITERATION:-?}. State preserved in git log."
    echo "Re-run the same command to resume."
    rm -f /tmp/pdc-context-$$-*.md /tmp/pdc-stderr-$$-*
    print_summary "INTERRUPTED"
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

debug "Verbose mode enabled"
debug "Timeout per phase: ${PHASE_TIMEOUT:-none}"
debug "Interactive mode: ${INTERACTIVE}"

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
    run_phase "planner" "planner" || true
    PHASE_TIMES_PLAN+=("$LAST_PHASE_DURATION")

    # ── DO PHASE ──
    run_phase "doer" "doer" || true
    PHASE_TIMES_DO+=("$LAST_PHASE_DURATION")

    # ── CHECK PHASE ──
    run_phase "checker" "checker" || true
    PHASE_TIMES_CHECK+=("$LAST_PHASE_DURATION")

    # ── EVALUATE VERDICT ──
    VERDICT=$(git log --grep="Loop-Verdict:" --grep="Loop-Iteration: ${ITERATION}" \
        --all-match --format="%B" -1 2>/dev/null \
        | sed -n 's/^Loop-Verdict: \(PASS\|FAIL\)$/\1/p' | head -1)
    VERDICT="${VERDICT:-}"

    # ── INTERACTIVE CHECKPOINT ──
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo "═══════════════════════════════════════════════"
        echo "  CHECKPOINT — Iteration ${ITERATION}"
        echo "  Verdict: ${VERDICT:-unknown}"
        echo "═══════════════════════════════════════════════"
        while true; do
            printf 'Continue? [c=continue / s=skip-to-next-iter / a=abort]: '
            read -r response < /dev/tty
            case "$response" in
                c|C|continue)  break ;;
                s|S|skip)      VERDICT="FAIL"; break ;;
                a|A|abort)
                    echo "Aborted by user."
                    print_summary "ABORTED"
                    exit 130
                    ;;
                *) echo "Please enter c, s, or a" ;;
            esac
        done
    fi

    if [ "$VERDICT" = "PASS" ]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  PASS — Task complete after ${ITERATION} iteration(s)   "
        echo "╚══════════════════════════════════════════════════════════╝"
        print_summary "PASS"
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
print_summary "FAIL (max iterations reached)"
exit 1
