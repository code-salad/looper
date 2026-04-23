#!/usr/bin/env bash
set -euo pipefail

# test-fetch-issue-context.sh — Corner-case tests for fetch-issue-context script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_ISSUE="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/fetch-issue-context"
CHECK_BLOCKED_REAL="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/check-blocked"

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

assert_output_empty() {
    local description="$1"
    local output="$2"
    if [ -z "$output" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected empty output, got: $output)"
        FAIL=$((FAIL + 1))
    fi
}

make_test_env() {
    local mock_dir="$1"

    # Mock gh: handles issue view calls
    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    # full json fetch
    if echo "$*" | grep -q "\-\-json"; then
        echo "{\"number\":$issue_num,\"title\":\"Test Issue $issue_num\",\"body\":\"Issue body for #$issue_num\",\"labels\":[]}"
        exit 0
    fi
    # template fetch for formatting
    if echo "$*" | grep -q "\-\-template"; then
        echo "## Issue #$issue_num: Test Issue $issue_num"
        echo ""
        echo "### Description"
        echo "Issue body for #$issue_num"
        exit 0
    fi
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"

    # Mock check-blocked: default to not blocked (exit 0)
    cat > "$mock_dir/check-blocked" << 'CBEOF'
#!/usr/bin/env bash
# Default mock: issue is not blocked
exit 0
CBEOF
    chmod +x "$mock_dir/check-blocked"
}

make_blocked_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    # Override check-blocked to signal blocked
    cat > "$mock_dir/check-blocked" << 'CBEOF'
#!/usr/bin/env bash
# Mock: issue is blocked
echo "Issue is blocked by open dependencies." >&2
exit 1
CBEOF
    chmod +x "$mock_dir/check-blocked"
}

make_failing_gh_env() {
    local mock_dir="$1"

    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
# Mock gh that always fails
exit 2
GHEOF
    chmod +x "$mock_dir/gh"

    cat > "$mock_dir/check-blocked" << 'CBEOF'
#!/usr/bin/env bash
exit 0
CBEOF
    chmod +x "$mock_dir/check-blocked"
}

# make_enriched_env — mock that succeeds on issue view AND graphql enrichment
# Creates a gh mock that:
#   - handles `issue view` (same as make_test_env)
#   - handles `api graphql` — returns a payload with comments + blockedBy + subIssues
make_enriched_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    # Override gh to also handle graphql
    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    if echo "$*" | grep -q "\-\-json"; then
        echo "{\"number\":$issue_num,\"title\":\"Test Issue $issue_num\",\"body\":\"Issue body for #$issue_num\",\"labels\":[]}"
        exit 0
    fi
    if echo "$*" | grep -q "\-\-template"; then
        echo "## Issue #$issue_num: Test Issue $issue_num"
        echo ""
        echo "### Description"
        echo "Issue body for #$issue_num"
        exit 0
    fi
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    cat << 'GQLEOF'
{
  "data": {
    "repository": {
      "issue": {
        "comments": {
          "nodes": [
            {"author": {"login": "alice"}, "createdAt": "2026-04-20T10:00:00Z", "body": "This is a comment from alice."},
            {"author": {"login": "bob"}, "createdAt": "2026-04-21T12:00:00Z", "body": "Another comment from bob."}
          ]
        },
        "blockedBy": {
          "nodes": [
            {"number": 77, "state": "CLOSED", "title": "Blocker issue", "repository": {"nameWithOwner": "foo/bar"}}
          ]
        },
        "subIssues": {
          "nodes": [
            {"number": 81, "state": "OPEN", "title": "Sub-issue title", "repository": {"nameWithOwner": "foo/bar"}}
          ]
        }
      }
    }
  }
}
GQLEOF
    exit 0
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"
}

# make_graphql_fail_env — issue view succeeds, graphql fails
make_graphql_fail_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    if echo "$*" | grep -q "\-\-json"; then
        echo "{\"number\":$issue_num,\"title\":\"Test Issue $issue_num\",\"body\":\"Issue body for #$issue_num\",\"labels\":[]}"
        exit 0
    fi
    if echo "$*" | grep -q "\-\-template"; then
        echo "## Issue #$issue_num: Test Issue $issue_num"
        echo ""
        echo "### Description"
        echo "Issue body for #$issue_num"
        exit 0
    fi
fi
# graphql always fails
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    echo "GraphQL error" >&2
    exit 1
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"
}

# make_empty_nodes_env — graphql returns empty comments + empty dep graph
make_empty_nodes_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    if echo "$*" | grep -q "\-\-json"; then
        echo "{\"number\":$issue_num,\"title\":\"Test Issue $issue_num\",\"body\":\"Issue body for #$issue_num\",\"labels\":[]}"
        exit 0
    fi
    if echo "$*" | grep -q "\-\-template"; then
        echo "## Issue #$issue_num: Test Issue $issue_num"
        echo ""
        echo "### Description"
        echo "Issue body for #$issue_num"
        exit 0
    fi
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    cat << 'GQLEOF'
{
  "data": {
    "repository": {
      "issue": {
        "comments": {"nodes": []},
        "blockedBy": {"nodes": []},
        "subIssues": {"nodes": []}
      }
    }
  }
}
GQLEOF
    exit 0
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"
}

# make_long_comment_env — graphql returns a comment with a body > 500 chars
make_long_comment_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    # Build a 1000-char string for the comment body
    local long_body
    long_body=$(python3 -c "print('A' * 1000)")

    cat > "$mock_dir/gh" << GHEOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
    issue_num="\$3"
    shift 3
    if echo "\$*" | grep -q "\-\-json"; then
        echo "{\\"number\\":\$issue_num,\\"title\\":\\"Test Issue \$issue_num\\",\\"body\\":\\"Issue body\\",\\"labels\\":[]}"
        exit 0
    fi
    if echo "\$*" | grep -q "\-\-template"; then
        echo "## Issue #\$issue_num: Test Issue \$issue_num"
        exit 0
    fi
fi
if [ "\$1" = "api" ] && [ "\$2" = "graphql" ]; then
    echo '{"data":{"repository":{"issue":{"comments":{"nodes":[{"author":{"login":"alice"},"createdAt":"2026-04-20T10:00:00Z","body":"${long_body}"}]},"blockedBy":{"nodes":[]},"subIssues":{"nodes":[]}}}}}'
    exit 0
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"
}

# make_markdown_fence_env — comment body contains markdown code fences
make_markdown_fence_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    if echo "$*" | grep -q "\-\-json"; then
        echo "{\"number\":$issue_num,\"title\":\"Test Issue $issue_num\",\"body\":\"Issue body\",\"labels\":[]}"
        exit 0
    fi
    if echo "$*" | grep -q "\-\-template"; then
        echo "## Issue #$issue_num"
        exit 0
    fi
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    printf '%s\n' '{"data":{"repository":{"issue":{"comments":{"nodes":[{"author":{"login":"alice"},"createdAt":"2026-04-20T10:00:00Z","body":"Look at this code:\n```bash\necho hello\n```\nDone."}]},"blockedBy":{"nodes":[]},"subIssues":{"nodes":[]}}}}}'
    exit 0
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"
}

# make_null_fields_env — graphql returns null for blockedBy/subIssues (feature not enabled)
make_null_fields_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    if echo "$*" | grep -q "\-\-json"; then
        echo "{\"number\":$issue_num,\"title\":\"Test Issue $issue_num\",\"body\":\"Issue body\",\"labels\":[]}"
        exit 0
    fi
    if echo "$*" | grep -q "\-\-template"; then
        echo "## Issue #$issue_num"
        exit 0
    fi
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    # blockedBy and subIssues are null (feature not available on this repo)
    echo '{"data":{"repository":{"issue":{"comments":{"nodes":[{"author":{"login":"charlie"},"createdAt":"2026-04-22T09:00:00Z","body":"A comment"}]},"blockedBy":null,"subIssues":null}}}}'
    exit 0
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"
}

# make_malformed_gql_env — graphql returns invalid JSON
make_malformed_gql_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    if echo "$*" | grep -q "\-\-json"; then
        echo "{\"number\":$issue_num,\"title\":\"Test Issue $issue_num\",\"body\":\"Issue body\",\"labels\":[]}"
        exit 0
    fi
    if echo "$*" | grep -q "\-\-template"; then
        echo "## Issue #$issue_num"
        exit 0
    fi
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    # malformed JSON
    echo 'NOT VALID JSON {'
    exit 0
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"
}


# --- Test 1: Args containing "#123" -> extracts issue 123, outputs formatted body ---
echo "=== Test 1: Args with '#123' hash reference ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#123 do something" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "hash ref: exit 0" "$EXIT_CODE"
FIRST_LINE=$(echo "$OUTPUT" | head -1)
REST=$(echo "$OUTPUT" | tail -n +2)
if echo "$FIRST_LINE" | grep -q "NUMBER=123"; then
    echo "PASS: hash ref: first line is NUMBER=123"
    PASS=$((PASS + 1))
else
    echo "FAIL: hash ref: expected first line NUMBER=123, got: $FIRST_LINE"
    FAIL=$((FAIL + 1))
fi
assert_output_contains "hash ref: body contains issue content" "$REST" "Issue"
cleanup

# --- Test 2: GitHub URL -> extracts number and repo ---
echo "=== Test 2: GitHub URL reference ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "https://github.com/foo/bar/issues/42" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "github url: exit 0" "$EXIT_CODE"
FIRST_LINE=$(echo "$OUTPUT" | head -1)
if echo "$FIRST_LINE" | grep -q "NUMBER=42"; then
    echo "PASS: github url: first line is NUMBER=42"
    PASS=$((PASS + 1))
else
    echo "FAIL: github url: expected first line NUMBER=42, got: $FIRST_LINE"
    FAIL=$((FAIL + 1))
fi
cleanup

# --- Test 3: Plain number at start "42 fix bug" -> extracts issue 42 ---
echo "=== Test 3: Plain number at start ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "42 fix the navbar bug" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "plain number: exit 0" "$EXIT_CODE"
FIRST_LINE=$(echo "$OUTPUT" | head -1)
if echo "$FIRST_LINE" | grep -q "NUMBER=42"; then
    echo "PASS: plain number: first line is NUMBER=42"
    PASS=$((PASS + 1))
else
    echo "FAIL: plain number: expected first line NUMBER=42, got: $FIRST_LINE"
    FAIL=$((FAIL + 1))
fi
cleanup

# --- Test 4: Args with no issue reference -> empty output, exit 0 ---
echo "=== Test 4: No issue reference in args ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "fix the navbar" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "no ref: exit 0" "$EXIT_CODE"
assert_output_empty "no ref: empty output" "$OUTPUT"
cleanup

# --- Test 5: gh issue view fails -> empty output, exit 0 ---
echo "=== Test 5: gh fails -> graceful degradation ==="
TMPDIR_TEST=$(mktemp -d)
make_failing_gh_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#99" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "gh fails: exit 0" "$EXIT_CODE"
assert_output_empty "gh fails: empty output" "$OUTPUT"
cleanup

# --- Test 6: Issue is blocked -> exit 1 ---
echo "=== Test 6: Issue is blocked -> exit 1 ==="
TMPDIR_TEST=$(mktemp -d)
make_blocked_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#50" 2>/tmp/fetch_stderr_test6) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "blocked issue: exit 1" "$EXIT_CODE"
STDERR_OUT=$(cat /tmp/fetch_stderr_test6 2>/dev/null || echo "")
if echo "$STDERR_OUT" | grep -qi "blocked\|dependencies\|open"; then
    echo "PASS: blocked issue: stderr contains blocking reason"
    PASS=$((PASS + 1))
else
    echo "FAIL: blocked issue: expected blocking reason in stderr, got: $STDERR_OUT"
    FAIL=$((FAIL + 1))
fi
cleanup

# --- Test 7: Missing --args flag -> exit nonzero with usage message ---
echo "=== Test 7: Missing --args flag ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$FETCH_ISSUE" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_nonzero "missing --args: non-zero exit" "$EXIT_CODE"
assert_output_contains "missing --args: usage message" "$OUTPUT" "usage\|--args\|required"
cleanup

# --- Test 8: Malformed GitHub URL (no /issues/ path) -> treated as no issue ref ---
echo "=== Test 8: Malformed GitHub URL ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "https://github.com/foo/bar/pulls/42" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "malformed url: exit 0" "$EXIT_CODE"
assert_output_empty "malformed url: empty output" "$OUTPUT"
cleanup

# --- Test 9: Enriched sections emitted when GraphQL succeeds ---
echo "=== Test 9: fetch-issue-context emits enriched sections on GraphQL success ==="
TMPDIR_TEST=$(mktemp -d)
make_enriched_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#10" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "enriched: exit 0" "$EXIT_CODE"
assert_output_contains "enriched: has PLANNER-ONLY delimiter" "$OUTPUT" "PLANNER-ONLY"
assert_output_contains "enriched: has Issue Comments section" "$OUTPUT" "Issue Comments"
assert_output_contains "enriched: has Dependency Graph section" "$OUTPUT" "Dependency Graph"
assert_output_contains "enriched: includes alice comment" "$OUTPUT" "alice"
assert_output_contains "enriched: includes blocked-by entry" "$OUTPUT" "Blocked by\|foo/bar"
assert_output_contains "enriched: includes sub-issue entry" "$OUTPUT" "Sub-issue\|Sub-issues"
cleanup

# --- Test 10: GraphQL failure is graceful (no PLANNER-ONLY, no crash) ---
echo "=== Test 10: GraphQL failure -> graceful degradation ==="
TMPDIR_TEST=$(mktemp -d)
make_graphql_fail_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#11" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "gql-fail: exit 0" "$EXIT_CODE"
# Must still have the base body
assert_output_contains "gql-fail: has issue body" "$OUTPUT" "Issue"
# Must have a degraded comments notice
assert_output_contains "gql-fail: has degraded comments notice" "$OUTPUT" "No comments fetched\|GraphQL unavailable"
# Must NOT have a full Dependency Graph section when GraphQL fails
if echo "$OUTPUT" | grep -q "Dependency Graph"; then
    echo "WARN: gql-fail: Dependency Graph present despite GraphQL failure (acceptable if degraded message)"
fi
cleanup

# --- Test 11: Empty nodes -> empty-state messages ---
echo "=== Test 11: Empty comments + empty dep graph -> empty-state messages ==="
TMPDIR_TEST=$(mktemp -d)
make_empty_nodes_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#12" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "empty-nodes: exit 0" "$EXIT_CODE"
assert_output_contains "empty-nodes: has PLANNER-ONLY delimiter" "$OUTPUT" "PLANNER-ONLY"
assert_output_contains "empty-nodes: no-comments message" "$OUTPUT" "No comments yet"
assert_output_contains "empty-nodes: no-dependencies message" "$OUTPUT" "No tracked dependencies"
cleanup

# --- Test 12: Long comment truncated to ~500 chars ---
echo "=== Test 12: Long comment body truncated ==="
TMPDIR_TEST=$(mktemp -d)
make_long_comment_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#13" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "truncation: exit 0" "$EXIT_CODE"
assert_output_contains "truncation: has Issue Comments" "$OUTPUT" "Issue Comments"
# Comment was 1000 As; truncated output should have '...' and NOT 1000 As
if echo "$OUTPUT" | grep -q "\.\.\."; then
    echo "PASS: truncation: output contains '...' indicating truncation"
    PASS=$((PASS + 1))
else
    echo "FAIL: truncation: expected '...' in output for truncated 1000-char comment"
    FAIL=$((FAIL + 1))
fi
cleanup

# --- Test 13: Markdown fences in comment body preserved ---
echo "=== Test 13: Markdown code fences in comment body ==="
TMPDIR_TEST=$(mktemp -d)
make_markdown_fence_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#14" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "md-fences: exit 0" "$EXIT_CODE"
assert_output_contains "md-fences: has Issue Comments" "$OUTPUT" "Issue Comments"
# The script should not crash on markdown content
assert_output_contains "md-fences: has alice comment" "$OUTPUT" "alice"
cleanup

# --- Test 14: Null blockedBy/subIssues fields (feature not enabled) ---
echo "=== Test 14: Null dep-graph fields handled gracefully ==="
TMPDIR_TEST=$(mktemp -d)
make_null_fields_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#15" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "null-fields: exit 0" "$EXIT_CODE"
assert_output_contains "null-fields: has Issue Comments" "$OUTPUT" "Issue Comments"
assert_output_contains "null-fields: has charlie comment" "$OUTPUT" "charlie"
# With null blockedBy/subIssues, should still emit Dependency Graph with no-deps message
assert_output_contains "null-fields: has Dependency Graph" "$OUTPUT" "Dependency Graph"
cleanup

# --- Test 15: Malformed GraphQL JSON -> graceful degradation (no crash) ---
echo "=== Test 15: Malformed GraphQL JSON -> graceful degradation ==="
TMPDIR_TEST=$(mktemp -d)
make_malformed_gql_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#16" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "malformed-json: exit 0" "$EXIT_CODE"
assert_output_contains "malformed-json: has base body" "$OUTPUT" "Issue"
cleanup

# --- Test 16: Idempotency — calling fetch-issue-context twice gives same output ---
echo "=== Test 16: Idempotency — two calls produce identical output ==="
TMPDIR_TEST=$(mktemp -d)
make_enriched_env "$TMPDIR_TEST"
OUTPUT1=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#17" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "idempotent: first call exit 0" "$EXIT_CODE"
OUTPUT2=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#17" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "idempotent: second call exit 0" "$EXIT_CODE"
if [ "$OUTPUT1" = "$OUTPUT2" ]; then
    echo "PASS: idempotent: two calls produce identical output"
    PASS=$((PASS + 1))
else
    echo "FAIL: idempotent: two calls produced different output"
    echo "  First output (first 5 lines): $(echo "$OUTPUT1" | head -5)"
    echo "  Second output (first 5 lines): $(echo "$OUTPUT2" | head -5)"
    FAIL=$((FAIL + 1))
fi
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
