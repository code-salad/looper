#!/usr/bin/env bash
set -euo pipefail

# test-detect-stack.sh — Corner-case tests for the detect-stack script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT_STACK="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/detect-stack"

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

assert_json_field() {
    local description="$1"
    local json="$2"
    local field="$3"
    local expected="$4"
    local actual
    actual=$(echo "$json" | jq -r ".$field" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected $field='$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_contains() {
    local description="$1"
    local json="$2"
    local field="$3"
    local expected="$4"
    local actual
    actual=$(echo "$json" | jq -r ".$field | @json" 2>/dev/null || echo "PARSE_ERROR")
    if echo "$actual" | grep -q "$expected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected $field to contain '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_bool() {
    local description="$1"
    local json="$2"
    local field="$3"
    local expected="$4"
    local actual
    actual=$(echo "$json" | jq -r ".$field" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected $field=$expected, got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

run_detect_stack() {
    local dir="$1"
    (cd "$dir" && "$DETECT_STACK" 2>/dev/null)
}

# --- Test 1: Empty directory -> all fields "none", ecosystems [] ---
echo "=== Test 1: Empty directory ==="
TMPDIR_TEST=$(mktemp -d)
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "empty dir: language=none" "$OUTPUT" "language" "none"
assert_json_field "empty dir: runtime=none" "$OUTPUT" "runtime" "none"
assert_json_field "empty dir: package_manager=none" "$OUTPUT" "package_manager" "none"
assert_json_field "empty dir: test_runner=none" "$OUTPUT" "test_runner" "none"
assert_json_field "empty dir: ecosystems=[]" "$OUTPUT" "ecosystems | length" "0"
cleanup

# --- Test 2: Node.js with tsconfig.json -> language=typescript, type_checker=tsc ---
echo "=== Test 2: Node.js + tsconfig.json ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"name":"test","dependencies":{}}' > "$TMPDIR_TEST/package.json"
echo '{}' > "$TMPDIR_TEST/tsconfig.json"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "node+ts: language=typescript" "$OUTPUT" "language" "typescript"
assert_json_field "node+ts: type_checker=tsc" "$OUTPUT" "type_checker" "tsc"
assert_json_field "node+ts: runtime=node" "$OUTPUT" "runtime" "node"
cleanup

# --- Test 3: pnpm-lock.yaml -> package_manager=pnpm ---
echo "=== Test 3: pnpm-lock.yaml ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"name":"test"}' > "$TMPDIR_TEST/package.json"
touch "$TMPDIR_TEST/pnpm-lock.yaml"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "pnpm: package_manager=pnpm" "$OUTPUT" "package_manager" "pnpm"
cleanup

# --- Test 4: bun.lockb -> package_manager=bun, runtime=bun ---
echo "=== Test 4: bun.lockb ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"name":"test"}' > "$TMPDIR_TEST/package.json"
touch "$TMPDIR_TEST/bun.lockb"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "bun: package_manager=bun" "$OUTPUT" "package_manager" "bun"
assert_json_field "bun: runtime=bun" "$OUTPUT" "runtime" "bun"
cleanup

# --- Test 5: pyproject.toml with [tool.pytest] -> test_runner=pytest ---
echo "=== Test 5: Python + pytest ==="
TMPDIR_TEST=$(mktemp -d)
printf '[tool.pytest.ini_options]\ntestpaths = ["tests"]\n' > "$TMPDIR_TEST/pyproject.toml"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "python+pytest: language=python" "$OUTPUT" "language" "python"
assert_json_field "python+pytest: test_runner=pytest" "$OUTPUT" "test_runner" "pytest"
cleanup

# --- Test 6: Python with uv.lock -> package_manager=uv ---
echo "=== Test 6: Python + uv.lock ==="
TMPDIR_TEST=$(mktemp -d)
touch "$TMPDIR_TEST/pyproject.toml"
touch "$TMPDIR_TEST/uv.lock"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "python+uv: package_manager=uv" "$OUTPUT" "package_manager" "uv"
cleanup

# --- Test 7: Go project -> all go defaults ---
echo "=== Test 7: Go project ==="
TMPDIR_TEST=$(mktemp -d)
echo 'module example.com/hello' > "$TMPDIR_TEST/go.mod"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "go: language=go" "$OUTPUT" "language" "go"
assert_json_field "go: runtime=go" "$OUTPUT" "runtime" "go"
assert_json_field "go: package_manager=go-modules" "$OUTPUT" "package_manager" "go-modules"
assert_json_field "go: test_runner=go-test" "$OUTPUT" "test_runner" "go-test"
assert_json_field "go: formatter=gofmt" "$OUTPUT" "formatter" "gofmt"
cleanup

# --- Test 8: Rust project -> all rust defaults ---
echo "=== Test 8: Rust project ==="
TMPDIR_TEST=$(mktemp -d)
printf '[package]\nname = "hello"\nversion = "0.1.0"\n' > "$TMPDIR_TEST/Cargo.toml"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "rust: language=rust" "$OUTPUT" "language" "rust"
assert_json_field "rust: package_manager=cargo" "$OUTPUT" "package_manager" "cargo"
assert_json_field "rust: test_runner=cargo-test" "$OUTPUT" "test_runner" "cargo-test"
assert_json_field "rust: linter=clippy" "$OUTPUT" "linter" "clippy"
assert_json_field "rust: formatter=rustfmt" "$OUTPUT" "formatter" "rustfmt"
cleanup

# --- Test 9: .NET csproj -> language=csharp ---
echo "=== Test 9: .NET csproj ==="
TMPDIR_TEST=$(mktemp -d)
echo '<Project Sdk="Microsoft.NET.Sdk"></Project>' > "$TMPDIR_TEST/MyApp.csproj"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "dotnet: language=csharp" "$OUTPUT" "language" "csharp"
assert_json_field "dotnet: runtime=dotnet" "$OUTPUT" "runtime" "dotnet"
assert_json_field "dotnet: package_manager=nuget" "$OUTPUT" "package_manager" "nuget"
cleanup

# --- Test 10: F# fsproj -> language=fsharp ---
echo "=== Test 10: F# fsproj ==="
TMPDIR_TEST=$(mktemp -d)
echo '<Project Sdk="Microsoft.NET.Sdk"></Project>' > "$TMPDIR_TEST/MyApp.fsproj"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "fsharp: language=fsharp" "$OUTPUT" "language" "fsharp"
cleanup

# --- Test 11: docker-compose.yml -> has_compose=true ---
echo "=== Test 11: docker-compose.yml present ==="
TMPDIR_TEST=$(mktemp -d)
echo 'services: {}' > "$TMPDIR_TEST/docker-compose.yml"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_bool "compose: has_compose=true" "$OUTPUT" "has_compose" "true"
cleanup

# --- Test 12: No docker-compose -> has_compose=false ---
echo "=== Test 12: No docker-compose ==="
TMPDIR_TEST=$(mktemp -d)
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_bool "no compose: has_compose=false" "$OUTPUT" "has_compose" "false"
cleanup

# --- Test 13: Monorepo subdirectory with package.json adds ecosystem ---
echo "=== Test 13: Monorepo detection ==="
TMPDIR_TEST=$(mktemp -d)
mkdir -p "$TMPDIR_TEST/frontend"
echo '{"name":"frontend"}' > "$TMPDIR_TEST/frontend/package.json"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_contains "monorepo: ecosystems has node:frontend" "$OUTPUT" "ecosystems" "node:frontend"
cleanup

# --- Test 14: package.json with scripts.dev -> dev_command=dev ---
echo "=== Test 14: dev command detection ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"name":"test","scripts":{"dev":"node server.js"}}' > "$TMPDIR_TEST/package.json"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "dev script: dev_command=dev" "$OUTPUT" "dev_command" "dev"
cleanup

# --- Test 15: Next framework -> dev_port=3000 ---
echo "=== Test 15: Next.js default port ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"name":"test","dependencies":{"next":"13.0.0"}}' > "$TMPDIR_TEST/package.json"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "next: framework=next" "$OUTPUT" "framework" "next"
assert_json_field "next: dev_port=3000" "$OUTPUT" "dev_port" "3000"
cleanup

# --- Test 16: Django framework -> dev_port=8000 ---
echo "=== Test 16: Django default port ==="
TMPDIR_TEST=$(mktemp -d)
printf '[tool.django]\n' > "$TMPDIR_TEST/pyproject.toml"
printf 'django = "4.0"\n' >> "$TMPDIR_TEST/pyproject.toml"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "django: dev_port=8000" "$OUTPUT" "dev_port" "8000"
cleanup

# --- Test 17: Vue framework -> dev_port=5173 ---
echo "=== Test 17: Vue default port ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"name":"test","dependencies":{"vue":"3.0.0"}}' > "$TMPDIR_TEST/package.json"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "vue: framework=vue" "$OUTPUT" "framework" "vue"
assert_json_field "vue: dev_port=5173" "$OUTPUT" "dev_port" "5173"
cleanup

# --- Test 18: .github/workflows -> ci=github-actions ---
echo "=== Test 18: GitHub Actions CI detection ==="
TMPDIR_TEST=$(mktemp -d)
mkdir -p "$TMPDIR_TEST/.github/workflows"
touch "$TMPDIR_TEST/.github/workflows/ci.yml"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "github-actions: ci=github-actions" "$OUTPUT" "ci" "github-actions"
cleanup

# --- Test 19: .gitlab-ci.yml -> ci=gitlab-ci ---
echo "=== Test 19: GitLab CI detection ==="
TMPDIR_TEST=$(mktemp -d)
touch "$TMPDIR_TEST/.gitlab-ci.yml"
OUTPUT=$(run_detect_stack "$TMPDIR_TEST")
assert_json_field "gitlab-ci: ci=gitlab-ci" "$OUTPUT" "ci" "gitlab-ci"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
