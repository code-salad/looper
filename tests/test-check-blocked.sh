#!/usr/bin/env bash
set -euo pipefail

# test-check-blocked.sh — Corner-case tests for the check-blocked script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_BLOCKED="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/check-blocked"

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

assert_exit_zero() {
    local description="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 0 ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit 0, got $exit_code)"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_nonzero() {
    local description="$1"
    local exit_code="$2"
    if [ "$exit_code" -ne 0 ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected non-zero exit, got 0)"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_one() {
    local description="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 1 ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit 1, got $exit_code)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_contains() {
    local description="$1"
    local output="$2"
    local expected="$3"
    if echo "$output" | grep -qi "$expected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected output to contain '$expected')"
        echo "  Actual output: $output"
        FAIL=$((FAIL + 1))
    fi
}

# Create a mock gh that reads from files in its own directory.
# issue_json.txt: JSON for the main issue view (labels, body)
# dep_states.txt: lines of "NUMBER STATE", e.g. "5 OPEN"
write_mock_gh() {
    local mock_dir="$1"
    cat > "$mock_dir/gh" << 'EOF'
#!/usr/bin/env bash
MOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    args="$*"
    # Full metadata fetch (labels,body or labels,body,state)
    if echo "$args" | grep -q -- "--json"; then
        json_fields=$(echo "$args" | grep -o -- '--json [^ ]*' | sed 's/--json //')
        if echo "$json_fields" | grep -q "body\|labels"; then
            if [ -f "$MOCK_DIR/issue_json.txt" ]; then
                cat "$MOCK_DIR/issue_json.txt"
            else
                echo '{"labels":[],"body":""}'
            fi
            exit 0
        fi
        if echo "$json_fields" | grep -q "state"; then
            # Dep state lookup
            state="CLOSED"
            if [ -f "$MOCK_DIR/dep_states.txt" ]; then
                match=$(grep "^${issue_num} " "$MOCK_DIR/dep_states.txt" 2>/dev/null || true)
                if [ -n "$match" ]; then
                    state=$(echo "$match" | awk '{print $2}')
                fi
            fi
            # Handle --jq '.state' flag - just output the state
            echo "$state"
            exit 0
        fi
    fi
fi
exit 1
EOF
    chmod +x "$mock_dir/gh"
}

# --- Test 1: No blocking labels, no deps, no blocked-by refs -> exit 0 ---
echo "=== Test 1: Clean issue (not blocked) ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"labels":[],"body":"Just a simple issue with no dependencies."}' > "$TMPDIR_TEST/issue_json.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 1 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "clean issue: exit 0" "$EXIT_CODE"
cleanup

# --- Test 2: Label containing "blocked" -> exit 1 ---
echo "=== Test 2: Label with 'blocked' ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"labels":[{"name":"blocked"}],"body":"This issue is blocked."}' > "$TMPDIR_TEST/issue_json.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 2 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "blocked label: exit 1" "$EXIT_CODE"
assert_output_contains "blocked label: output contains reason" "$OUTPUT" "blocked"
cleanup

# --- Test 3: Label containing "dependencies" -> exit 1 ---
echo "=== Test 3: Label with 'dependencies' ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"labels":[{"name":"dependencies"}],"body":"Dependency issue."}' > "$TMPDIR_TEST/issue_json.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 3 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "dependencies label: exit 1" "$EXIT_CODE"
cleanup

# --- Test 4: "- [ ] Depends on #5" where #5 is OPEN -> exit 1 ---
echo "=== Test 4: Task-list dep 'Depends on #5' with OPEN dep ==="
TMPDIR_TEST=$(mktemp -d)
printf '{"labels":[],"body":"This depends on another issue.\\n- [ ] Depends on #5\\nSome more text."}\n' > "$TMPDIR_TEST/issue_json.txt"
printf '5 OPEN\n' > "$TMPDIR_TEST/dep_states.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 4 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "depends-on OPEN: exit 1" "$EXIT_CODE"
cleanup

# --- Test 5: "- [ ] Depends on #5" where #5 is CLOSED -> exit 0 ---
echo "=== Test 5: Task-list dep 'Depends on #5' with CLOSED dep ==="
TMPDIR_TEST=$(mktemp -d)
printf '{"labels":[],"body":"- [ ] Depends on #5\\nThis dependency is satisfied."}\n' > "$TMPDIR_TEST/issue_json.txt"
printf '5 CLOSED\n' > "$TMPDIR_TEST/dep_states.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 5 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "depends-on CLOSED: exit 0" "$EXIT_CODE"
cleanup

# --- Test 6: "- [ ] #7" where #7 is OPEN -> exit 1 ---
echo "=== Test 6: Task-list dep '#7' (no 'Depends on') with OPEN dep ==="
TMPDIR_TEST=$(mktemp -d)
printf '{"labels":[],"body":"Checklist:\\n- [ ] #7\\n- [x] Something done"}\n' > "$TMPDIR_TEST/issue_json.txt"
printf '7 OPEN\n' > "$TMPDIR_TEST/dep_states.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 6 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "task-list #N OPEN: exit 1" "$EXIT_CODE"
cleanup

# --- Test 7: "Blocked by #3" where #3 is OPEN -> exit 1 ---
echo "=== Test 7: 'Blocked by #3' with OPEN dep ==="
TMPDIR_TEST=$(mktemp -d)
printf '{"labels":[],"body":"This feature requires auth.\\nBlocked by #3\\nWill implement after."}\n' > "$TMPDIR_TEST/issue_json.txt"
printf '3 OPEN\n' > "$TMPDIR_TEST/dep_states.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 7 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "blocked-by OPEN: exit 1" "$EXIT_CODE"
cleanup

# --- Test 8: "blocked by #3" (lowercase) where #3 is CLOSED -> exit 0 ---
echo "=== Test 8: 'blocked by #3' (case-insensitive) with CLOSED dep ==="
TMPDIR_TEST=$(mktemp -d)
printf '{"labels":[],"body":"blocked by #3\\nNow resolved."}\n' > "$TMPDIR_TEST/issue_json.txt"
printf '3 CLOSED\n' > "$TMPDIR_TEST/dep_states.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 8 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "blocked-by CLOSED: exit 0" "$EXIT_CODE"
cleanup

# --- Test 9: Missing --issue flag -> exit nonzero with usage message ---
echo "=== Test 9: Missing --issue flag ==="
TMPDIR_TEST=$(mktemp -d)
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_nonzero "missing --issue: non-zero exit" "$EXIT_CODE"
assert_output_contains "missing --issue: usage in output" "$OUTPUT" "usage\|--issue\|required"
cleanup

# --- Test 10: Issue with empty body (null) -> exit 0 ---
echo "=== Test 10: Empty/null body ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"labels":[],"body":null}' > "$TMPDIR_TEST/issue_json.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 10 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "null body: exit 0" "$EXIT_CODE"
cleanup

# --- Test 11: Issue with no labels field -> exit 0 ---
echo "=== Test 11: No labels field ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"body":"Some body text with no labels."}' > "$TMPDIR_TEST/issue_json.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 11 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "no labels field: exit 0" "$EXIT_CODE"
cleanup

# --- Test 12: Multiple blocking conditions -> exit 1 ---
echo "=== Test 12: Multiple blocking conditions ==="
TMPDIR_TEST=$(mktemp -d)
echo '{"labels":[{"name":"blocked"}],"body":"Blocked by #5\n- [ ] Depends on #6"}' > "$TMPDIR_TEST/issue_json.txt"
printf '5 OPEN\n6 OPEN\n' > "$TMPDIR_TEST/dep_states.txt"
write_mock_gh "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$CHECK_BLOCKED" --issue 12 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "multiple conditions: exit 1" "$EXIT_CODE"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
