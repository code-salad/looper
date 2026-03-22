#!/usr/bin/env bash
set -euo pipefail

# test-integration-ci.sh — Verify integration test infrastructure:
# 1. scaffold-integration-ci generates valid workflows for each stack
# 2. run-integration-tests script exists and is executable
# 3. Doer/checker agents reference integration test phase
# 4. create-github-pr scaffolds CI when integration tests exist

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/skills/looper/scripts"
AGENTS_DIR="$REPO_ROOT/agents"
PR_SKILL="$REPO_ROOT/skills/create-github-pr/SKILL.md"

PASS=0
FAIL=0

check() {
    local label="$1"
    local result="$2"

    if [ "$result" = "true" ]; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label"
        FAIL=$((FAIL + 1))
    fi
}

check_file_contains() {
    local label="$1"
    local file="$2"
    local pattern="$3"

    if grep -q "$pattern" "$file"; then
        check "$label" "true"
    else
        echo "  Expected pattern '$pattern' in $file"
        check "$label" "false"
    fi
}

# --- Script existence and permissions ---

check "scaffold-integration-ci exists" \
    "$([ -f "$SCRIPTS_DIR/scaffold-integration-ci" ] && echo true || echo false)"

check "scaffold-integration-ci is executable" \
    "$([ -x "$SCRIPTS_DIR/scaffold-integration-ci" ] && echo true || echo false)"

check "run-integration-tests exists" \
    "$([ -f "$SCRIPTS_DIR/run-integration-tests" ] && echo true || echo false)"

check "run-integration-tests is executable" \
    "$([ -x "$SCRIPTS_DIR/run-integration-tests" ] && echo true || echo false)"

# --- scaffold-integration-ci generates valid YAML for each stack ---

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

test_scaffold() {
    local stack_name="$1"
    local stack_json="$2"
    local workdir="$TMPDIR/$stack_name"

    mkdir -p "$workdir"
    cd "$workdir"
    git init -q

    STACK_JSON="$stack_json" "$SCRIPTS_DIR/scaffold-integration-ci" --force 2>/dev/null

    if [ -f ".github/workflows/integration.yml" ]; then
        # Basic YAML validity check (structure has required keys)
        if grep -q "name: Integration Tests" ".github/workflows/integration.yml" && \
           grep -q "pull_request:" ".github/workflows/integration.yml" && \
           grep -q "INTEGRATION_PORT:" ".github/workflows/integration.yml" && \
           grep -q "Run integration tests" ".github/workflows/integration.yml" && \
           grep -q "Stop application" ".github/workflows/integration.yml"; then
            check "scaffold generates valid workflow for $stack_name" "true"
        else
            check "scaffold generates valid workflow for $stack_name" "false"
            echo "  Generated file missing required sections"
        fi
    else
        check "scaffold generates valid workflow for $stack_name" "false"
        echo "  No workflow file generated"
    fi

    cd - > /dev/null
}

test_scaffold "node-npm" \
    '{"language":"typescript","runtime":"node","package_manager":"npm","test_runner":"vitest","linter":"eslint","formatter":"prettier","type_checker":"tsc","build_tool":"vite","framework":"next","ci":"none","dev_command":"dev","dev_port":"3000","ecosystems":["node"]}'

test_scaffold "node-pnpm" \
    '{"language":"typescript","runtime":"node","package_manager":"pnpm","test_runner":"vitest","linter":"eslint","formatter":"prettier","type_checker":"tsc","build_tool":"vite","framework":"express","ci":"none","dev_command":"dev","dev_port":"3000","ecosystems":["node"]}'

test_scaffold "python-uv" \
    '{"language":"python","runtime":"python","package_manager":"uv","test_runner":"pytest","linter":"ruff","formatter":"ruff","type_checker":"mypy","build_tool":"none","framework":"fastapi","ci":"none","dev_command":"none","dev_port":"8000","ecosystems":["python"]}'

test_scaffold "go" \
    '{"language":"go","runtime":"go","package_manager":"go-modules","test_runner":"go-test","linter":"golangci-lint","formatter":"gofmt","type_checker":"go-vet","build_tool":"go-build","framework":"gin","ci":"none","dev_command":"none","dev_port":"8080","ecosystems":["go"]}'

test_scaffold "rust" \
    '{"language":"rust","runtime":"rust","package_manager":"cargo","test_runner":"cargo-test","linter":"clippy","formatter":"rustfmt","type_checker":"cargo-check","build_tool":"cargo-build","framework":"none","ci":"none","dev_command":"none","dev_port":"none","ecosystems":["rust"]}'

test_scaffold "dotnet" \
    '{"language":"csharp","runtime":"dotnet","package_manager":"nuget","test_runner":"dotnet-test","linter":"dotnet-format","formatter":"dotnet-format","type_checker":"dotnet-build","build_tool":"dotnet-build","framework":"none","ci":"none","dev_command":"none","dev_port":"none","ecosystems":["dotnet"]}'

# --- scaffold-integration-ci skips when workflow already exists ---

skip_dir="$TMPDIR/skip-test"
mkdir -p "$skip_dir/.github/workflows"
cd "$skip_dir"
git init -q
echo "existing" > ".github/workflows/integration.yml"

output=$(STACK_JSON='{"language":"go","runtime":"go","package_manager":"go-modules","test_runner":"go-test","linter":"go-vet","formatter":"gofmt","type_checker":"go-vet","build_tool":"go-build","framework":"none","ci":"none","dev_command":"none","dev_port":"none","ecosystems":["go"]}' \
    "$SCRIPTS_DIR/scaffold-integration-ci" 2>&1)

if grep -q "existing" ".github/workflows/integration.yml"; then
    check "scaffold skips when workflow already exists" "true"
else
    check "scaffold skips when workflow already exists" "false"
fi
cd - > /dev/null

# --- Agent prompts reference integration tests ---

check_file_contains "doer.md references do-integration phase" \
    "$AGENTS_DIR/doer.md" \
    "do-integration"

check_file_contains "doer.md references run-integration-tests" \
    "$AGENTS_DIR/doer.md" \
    "run-integration-tests"

check_file_contains "doer.md references tests/integration directory" \
    "$AGENTS_DIR/doer.md" \
    "tests/integration"

check_file_contains "checker.md references integration test subagent" \
    "$AGENTS_DIR/checker.md" \
    "Integration Test Verifier"

check_file_contains "checker.md references run-integration-tests" \
    "$AGENTS_DIR/checker.md" \
    "run-integration-tests"

check_file_contains "checker.md references do-integration commit" \
    "$AGENTS_DIR/checker.md" \
    "do-integration"

# --- create-github-pr references scaffold ---

check_file_contains "create-github-pr scaffolds integration CI" \
    "$PR_SKILL" \
    "scaffold-integration-ci"

check_file_contains "create-github-pr checks for tests/integration" \
    "$PR_SKILL" \
    "tests/integration"

# --- Summary ---

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
