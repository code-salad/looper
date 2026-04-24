#!/usr/bin/env bash
set -euo pipefail

# test-issue-tooling.sh — Tests for validate-issue-body and list-ready-issues
# Runs against the scripts under plugins/looper/skills/looper/scripts/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE="$REPO_ROOT/plugins/looper/skills/looper/scripts/validate-issue-body"
LIST_READY="$REPO_ROOT/plugins/looper/skills/looper/scripts/list-ready-issues"

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

assert_exit_two() {
    local description="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 2 ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit 2, got $exit_code)"
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

assert_line_count() {
    local description="$1"
    local output="$2"
    local expected="$3"
    local actual
    if [ -z "$output" ]; then
        actual=0
    else
        actual=$(echo "$output" | wc -l | tr -d ' ')
    fi
    if [ "$actual" -eq "$expected" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected $expected lines, got $actual)"
        echo "  Actual output: $output"
        FAIL=$((FAIL + 1))
    fi
}

# Write a mock gh script for list-ready-issues tests
# Arguments: mock_dir, issue_list_json (what gh issue list returns),
#            dep_states (lines of "NUMBER STATE" for issue view state queries)
write_mock_gh_for_lri() {
    local mock_dir="$1"
    local issue_list_json="$2"
    local dep_states="${3:-}"

    # Write the issue list JSON to a file
    echo "$issue_list_json" > "$mock_dir/issue_list.json"
    if [ -n "$dep_states" ]; then
        echo "$dep_states" > "$mock_dir/dep_states.txt"
    fi

    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
MOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Record what was called (for --label flag test)
echo "$@" >> "$MOCK_DIR/gh_calls.log" 2>/dev/null || true

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    cat "$MOCK_DIR/issue_list.json"
    exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    args="$*"
    # Handle --json labels,body (used by check-blocked for main fetch)
    if echo "$args" | grep -q -- "--json"; then
        json_fields=$(echo "$args" | grep -o -- '--json [^ ]*' | sed 's/--json //')
        if echo "$json_fields" | grep -q "body\|labels"; then
            # Return issue data from our fixture
            if [ -f "$MOCK_DIR/issue_json_${issue_num}.txt" ]; then
                cat "$MOCK_DIR/issue_json_${issue_num}.txt"
            else
                echo '{"labels":[],"body":""}'
            fi
            exit 0
        fi
        if echo "$json_fields" | grep -q "state"; then
            # Dep state lookup — handle --jq '.state' case
            state="CLOSED"
            if [ -f "$MOCK_DIR/dep_states.txt" ]; then
                match=$(grep "^${issue_num} " "$MOCK_DIR/dep_states.txt" 2>/dev/null || true)
                if [ -n "$match" ]; then
                    state=$(echo "$match" | awk '{print $2}')
                fi
            fi
            echo "$state"
            exit 0
        fi
    fi
fi

# Fallback — unknown command
exit 1
GHEOF
    chmod +x "$mock_dir/gh"
}

# ============================================================
# Section A: validate-issue-body tests
# ============================================================

echo ""
echo "=== Section A: validate-issue-body tests ==="

# A1: Empty body (--file /dev/null) -> exit 0
echo "=== A1: Empty body -> exit 0 ==="
"$VALIDATE" --file /dev/null && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "A1: empty body: exit 0" "$EXIT_CODE"

# A2: Plain body with no refs -> exit 0
echo "=== A2: Plain body no refs -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nThis is a plain issue with no issue references.\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "A2: no refs: exit 0" "$EXIT_CODE"
cleanup

# A3: Ref in Description, no canonical section -> exit 1
echo "=== A3: Ref in Description, no canonical section -> exit 1 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nThis builds on #42 to extend behavior.\n\n## Motivation\nImportant change.\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "A3: ref in Description, no canonical section: exit 1" "$EXIT_CODE"
cleanup

# A4: Ref in Description, ## Dependencies present -> exit 0
echo "=== A4: Ref in Description, ## Dependencies present -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nThis builds on #42.\n\n## Dependencies\n- [ ] Depends on #42 — needed for auth\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "A4: ref with ## Dependencies present: exit 0" "$EXIT_CODE"
cleanup

# A5: Ref only in ## References -> exit 0
echo "=== A5: Ref only in ## References -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nA standalone improvement.\n\n## References\n- See #42 for prior art\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "A5: ref only in ## References: exit 0" "$EXIT_CODE"
cleanup

# A6: Ref only in ## Subtasks, no ## Dependencies / ## Blockers -> exit 1
# (## Subtasks is NOT a safe zone — check-blocked scans the full body)
echo "=== A6: Ref only in ## Subtasks, no canonical section -> exit 1 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nA standalone feature.\n\n## Subtasks\n- [ ] Implement after #42 lands\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "A6: ref in Subtasks, no canonical section: exit 1" "$EXIT_CODE"
cleanup

# A7: Ref only in ## Context -> exit 0
echo "=== A7: Ref only in ## Context -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nAn improvement.\n\n## Context\n- Found by reviewing #42 behavior\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "A7: ref only in ## Context: exit 0" "$EXIT_CODE"
cleanup

# A8: #abc (hex/non-digit) -> exit 0
echo "=== A8: #abc (non-digit) -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nSee commit #abc123 for details.\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "A8: #abc hex: exit 0" "$EXIT_CODE"
cleanup

# A9: PR URL /pull/123 -> exit 0 (no false positive from URL paths)
echo "=== A9: PR URL /pull/123 -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nSee https://github.com/owner/repo/pull/123 for context.\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "A9: PR URL /pull/123: exit 0" "$EXIT_CODE"
cleanup

# A10: ### Dependencies (h3) with ref outside it -> exit 1 (h3 doesn't count)
echo "=== A10: ### Dependencies (h3) with ref, no h2 canonical section -> exit 1 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nBuilds on #42.\n\n### Dependencies\nThis is h3, not h2.\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "A10: h3 Dependencies with ref outside: exit 1" "$EXIT_CODE"
cleanup

# A11: --quiet mode -> exit 1 with no stderr output
echo "=== A11: --quiet mode -> exit 1, no stderr ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nBuilds on #42.\n' > "$TMPDIR_TEST/body.md"
STDERR_OUT=$("$VALIDATE" --file "$TMPDIR_TEST/body.md" --quiet 2>&1 1>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "A11: --quiet mode: exit 1" "$EXIT_CODE"
assert_output_empty "A11: --quiet mode: no stderr output" "$STDERR_OUT"
cleanup

# ============================================================
# Section B: list-ready-issues tests (mocked gh)
# ============================================================

echo ""
echo "=== Section B: list-ready-issues tests ==="

# B1: Three open unassigned, none blocked -> 3 TSV lines, summary "Found 3 ... (0 blocked)"
echo "=== B1: Three issues, none blocked -> 3 TSV lines ==="
TMPDIR_TEST=$(mktemp -d)
ALL_JSON='[
  {"number":10,"title":"Issue Ten","labels":[],"createdAt":"2024-01-01T00:00:00Z"},
  {"number":20,"title":"Issue Twenty","labels":[],"createdAt":"2024-01-02T00:00:00Z"},
  {"number":30,"title":"Issue Thirty","labels":[],"createdAt":"2024-01-03T00:00:00Z"}
]'
# No blocking — all issues have empty bodies, no blocking labels
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_10.txt"
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_20.txt"
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_30.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
STDOUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>/tmp/lri_stderr_b1.txt) && EXIT_CODE=0 || EXIT_CODE=$?
STDERR=$(cat /tmp/lri_stderr_b1.txt)
assert_exit_zero "B1: exit 0" "$EXIT_CODE"
assert_line_count "B1: 3 TSV lines" "$STDOUT" 3
assert_output_contains "B1: summary has Found 3" "$STDERR" "Found 3"
assert_output_contains "B1: summary has 0 blocked" "$STDERR" "0 blocked"
cleanup

# B2: One blocked by label -> 2 TSV lines, summary "Found 2 ... (1 blocked)"
echo "=== B2: One blocked by label -> 2 TSV lines ==="
TMPDIR_TEST=$(mktemp -d)
ALL_JSON='[
  {"number":10,"title":"Issue Ten","labels":[],"createdAt":"2024-01-01T00:00:00Z"},
  {"number":20,"title":"Issue Twenty","labels":[{"name":"blocked","color":"red"}],"createdAt":"2024-01-02T00:00:00Z"},
  {"number":30,"title":"Issue Thirty","labels":[],"createdAt":"2024-01-03T00:00:00Z"}
]'
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_10.txt"
echo '{"labels":[{"name":"blocked"}],"body":""}' > "$TMPDIR_TEST/issue_json_20.txt"
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_30.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
STDOUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>/tmp/lri_stderr_b2.txt) && EXIT_CODE=0 || EXIT_CODE=$?
STDERR=$(cat /tmp/lri_stderr_b2.txt)
assert_exit_zero "B2: exit 0" "$EXIT_CODE"
assert_line_count "B2: 2 TSV lines" "$STDOUT" 2
assert_output_contains "B2: summary has Found 2" "$STDERR" "Found 2"
assert_output_contains "B2: summary has 1 blocked" "$STDERR" "1 blocked"
cleanup

# B3: One blocked by "Blocked by #99" ref to open #99 -> that issue filtered out
echo "=== B3: One blocked by dep ref -> filtered out ==="
TMPDIR_TEST=$(mktemp -d)
ALL_JSON='[
  {"number":10,"title":"Issue Ten","labels":[],"createdAt":"2024-01-01T00:00:00Z"},
  {"number":20,"title":"Issue Twenty","labels":[],"createdAt":"2024-01-02T00:00:00Z"},
  {"number":30,"title":"Issue Thirty","labels":[],"createdAt":"2024-01-03T00:00:00Z"}
]'
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_10.txt"
printf '{"labels":[],"body":"Blocked by #99\\nNeeds auth first."}\n' > "$TMPDIR_TEST/issue_json_20.txt"
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_30.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" "99 OPEN"
STDOUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>/tmp/lri_stderr_b3.txt) && EXIT_CODE=0 || EXIT_CODE=$?
STDERR=$(cat /tmp/lri_stderr_b3.txt)
assert_exit_zero "B3: exit 0" "$EXIT_CODE"
assert_line_count "B3: 2 TSV lines (blocked filtered)" "$STDOUT" 2
assert_output_contains "B3: summary has 1 blocked" "$STDERR" "1 blocked"
cleanup

# B4: --json mode -> valid JSON with required fields including createdAt
echo "=== B4: --json mode -> valid JSON with required fields ==="
TMPDIR_TEST=$(mktemp -d)
ALL_JSON='[
  {"number":10,"title":"Issue Ten","labels":[],"createdAt":"2024-01-01T00:00:00Z"},
  {"number":20,"title":"Issue Twenty","labels":[],"createdAt":"2024-01-02T00:00:00Z"}
]'
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_10.txt"
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_20.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
JSON_OUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" --json 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "B4: --json exit 0" "$EXIT_CODE"
echo "$JSON_OUT" | jq -e 'length == 2 and (.[0] | has("number") and has("title") and has("labels") and has("createdAt"))' > /dev/null 2>/dev/null && JQ_EXIT=0 || JQ_EXIT=$?
assert_exit_zero "B4: JSON has required fields (number,title,labels,createdAt)" "$JQ_EXIT"
cleanup

# B5: JSON labels is an array of strings, not objects
echo "=== B5: JSON labels are strings not objects ==="
TMPDIR_TEST=$(mktemp -d)
ALL_JSON='[
  {"number":10,"title":"Issue Ten","labels":[{"name":"enhancement","color":"blue"}],"createdAt":"2024-01-01T00:00:00Z"}
]'
echo '{"labels":[{"name":"enhancement"}],"body":""}' > "$TMPDIR_TEST/issue_json_10.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
JSON_OUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" --json 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "B5: --json exit 0" "$EXIT_CODE"
echo "$JSON_OUT" | jq -e '.[0].labels | all(. | type == "string")' > /dev/null 2>/dev/null && JQ_EXIT=0 || JQ_EXIT=$?
assert_exit_zero "B5: labels are strings not objects" "$JQ_EXIT"
cleanup

# B6: --label feature flag -> forwarded to gh
echo "=== B6: --label feature -> forwarded to gh ==="
TMPDIR_TEST=$(mktemp -d)
ALL_JSON='[{"number":10,"title":"Feature Issue","labels":[{"name":"feature"}],"createdAt":"2024-01-01T00:00:00Z"}]'
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_10.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" --label feature 2>/dev/null && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "B6: --label feature exit 0" "$EXIT_CODE"
# Check that --label feature was forwarded to gh
GH_CALLS=$(cat "$TMPDIR_TEST/gh_calls.log" 2>/dev/null || echo "")
assert_output_contains "B6: --label feature forwarded to gh" "$GH_CALLS" "feature"
cleanup

# B7: Sort order (TSV) oldest-first by createdAt
echo "=== B7: Sort order oldest-first ==="
TMPDIR_TEST=$(mktemp -d)
# Issues in reverse order in the list output
ALL_JSON='[
  {"number":30,"title":"Newest","labels":[],"createdAt":"2024-03-01T00:00:00Z"},
  {"number":10,"title":"Oldest","labels":[],"createdAt":"2024-01-01T00:00:00Z"},
  {"number":20,"title":"Middle","labels":[],"createdAt":"2024-02-01T00:00:00Z"}
]'
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_10.txt"
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_20.txt"
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_30.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
STDOUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
FIRST_LINE=$(echo "$STDOUT" | head -1)
assert_exit_zero "B7: exit 0" "$EXIT_CODE"
assert_output_contains "B7: first line is oldest (#10)" "$FIRST_LINE" "#10"
cleanup

# B8: Empty result -> 0 stdout lines, summary "Found 0 ... (0 blocked)", exit 0
echo "=== B8: Empty result -> 0 lines, exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
ALL_JSON='[]'
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
STDOUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>/tmp/lri_stderr_b8.txt) && EXIT_CODE=0 || EXIT_CODE=$?
STDERR=$(cat /tmp/lri_stderr_b8.txt)
assert_exit_zero "B8: empty list exit 0" "$EXIT_CODE"
assert_output_empty "B8: no stdout lines" "$STDOUT"
assert_output_contains "B8: summary Found 0" "$STDERR" "Found 0"
cleanup

# B9: gh failure -> list-ready-issues exit 2, error on stderr
echo "=== B9: gh failure -> exit 2 ==="
TMPDIR_TEST=$(mktemp -d)
cat > "$TMPDIR_TEST/gh" << 'GHEOF'
#!/usr/bin/env bash
echo "gh: error: network failure" >&2
exit 1
GHEOF
chmod +x "$TMPDIR_TEST/gh"
STDERR_OUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>&1 1>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_two "B9: gh failure exit 2" "$EXIT_CODE"
assert_output_contains "B9: stderr has error" "$STDERR_OUT" "error\|fail\|Error\|Fail"
cleanup

# ============================================================
# Section C: gh-issue-creator.md rule presence (static greps)
# ============================================================

echo ""
echo "=== Section C: gh-issue-creator.md rule presence ==="
GH_CREATOR="$REPO_ROOT/plugins/looper/agents/gh-issue-creator.md"

grep -q "Dep/blocker detection rule" "$GH_CREATOR" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "C1: gh-issue-creator has 'Dep/blocker detection rule'" "$EXIT_CODE"

grep -q "validate-issue-body" "$GH_CREATOR" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "C2: gh-issue-creator mentions validate-issue-body" "$EXIT_CODE"

grep -q "Refused — caller mentioned" "$GH_CREATOR" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "C3: gh-issue-creator has refusal message" "$EXIT_CODE"

# ============================================================
# Section D: planner.md / doer.md template extension
# ============================================================

echo ""
echo "=== Section D: planner.md / doer.md template extension ==="
PLANNER_MD="$REPO_ROOT/plugins/looper/agents/planner.md"
DOER_MD="$REPO_ROOT/plugins/looper/agents/doer.md"

grep -q "Dependencies: <#N" "$PLANNER_MD" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "D1: planner.md has Dependencies template" "$EXIT_CODE"

grep -q "Blockers: <#N" "$PLANNER_MD" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "D2: planner.md has Blockers template" "$EXIT_CODE"

grep -q "Dependencies: <#N" "$DOER_MD" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "D3: doer.md has Dependencies template" "$EXIT_CODE"

grep -q "Blockers: <#N" "$DOER_MD" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "D4: doer.md has Blockers template" "$EXIT_CODE"

# ============================================================
# Section E: looper-issue/SKILL.md migration
# ============================================================

echo ""
echo "=== Section E: looper-issue/SKILL.md migration ==="
LOOPER_ISSUE="$REPO_ROOT/plugins/looper/skills/looper-issue/SKILL.md"

grep -q "list-ready-issues --json" "$LOOPER_ISSUE" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "E1: looper-issue uses list-ready-issues --json" "$EXIT_CODE"

# Old raw gh issue list call should be removed
if grep -q 'gh issue list --state open --search "no:assignee" --limit 20' "$LOOPER_ISSUE"; then
    echo "FAIL: E2: old raw gh issue list call still present"
    FAIL=$((FAIL + 1))
else
    echo "PASS: E2: old raw gh issue list call removed"
    PASS=$((PASS + 1))
fi

grep -q "Found .* ready issues\|Found.*ready" "$LOOPER_ISSUE" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "E3: looper-issue has visibility line pattern" "$EXIT_CODE"

grep -q "mktemp" "$LOOPER_ISSUE" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "E4: looper-issue uses mktemp for stats capture" "$EXIT_CODE"

# ============================================================
# Section F: looper-ee/SKILL.md Phase 3c
# ============================================================

echo ""
echo "=== Section F: looper-ee/SKILL.md Phase 3c ==="
LOOPER_EE="$REPO_ROOT/plugins/looper/skills/looper-ee/SKILL.md"

grep -q "## Phase 3c: Pre-Worktree Blocked Check" "$LOOPER_EE" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "F1: looper-ee has Phase 3c heading" "$EXIT_CODE"

grep -q "UPSTREAM_OWNED" "$LOOPER_EE" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "F2: looper-ee Phase 3c re-derives UPSTREAM_OWNED" "$EXIT_CODE"

grep -qE 'check-blocked --issue.*--repo' "$LOOPER_EE" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "F3: looper-ee Phase 3c calls check-blocked with --issue and --repo" "$EXIT_CODE"

grep -q "Skipping blocked check" "$LOOPER_EE" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "F4: looper-ee Phase 3c skips when upstream-claimed" "$EXIT_CODE"

# ============================================================
# Section G: ISSUE_TEMPLATE existence
# ============================================================

echo ""
echo "=== Section G: .github/ISSUE_TEMPLATE/default.md ==="
ISSUE_TEMPLATE="$REPO_ROOT/.github/ISSUE_TEMPLATE/default.md"

[ -f "$ISSUE_TEMPLATE" ] && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "G1: .github/ISSUE_TEMPLATE/default.md exists" "$EXIT_CODE"

if [ -f "$ISSUE_TEMPLATE" ]; then
    grep -q "load-bearing" "$ISSUE_TEMPLATE" && EXIT_CODE=0 || EXIT_CODE=$?
    assert_exit_zero "G2: default.md contains 'load-bearing'" "$EXIT_CODE"

    grep -qE '^## Dependencies' "$ISSUE_TEMPLATE" && EXIT_CODE=0 || EXIT_CODE=$?
    assert_exit_zero "G3: default.md has ## Dependencies heading" "$EXIT_CODE"

    grep -qE '^## Blockers' "$ISSUE_TEMPLATE" && EXIT_CODE=0 || EXIT_CODE=$?
    assert_exit_zero "G4: default.md has ## Blockers heading" "$EXIT_CODE"
else
    echo "FAIL: G2: cannot check content (file missing)"
    FAIL=$((FAIL + 1))
    echo "FAIL: G3: cannot check content (file missing)"
    FAIL=$((FAIL + 1))
    echo "FAIL: G4: cannot check content (file missing)"
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Section H: Iteration 2 regression tests (H1–H12)
# ============================================================

echo ""
echo "=== Section H: Iteration 2 regression tests ==="

# H1: gh stderr noise must not poison JSON capture
echo "=== H1: gh stderr noise + valid JSON -> issue still surfaced ==="
TMPDIR_TEST=$(mktemp -d)
cat > "$TMPDIR_TEST/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    echo "gh: warning: token will expire in 7 days" >&2
    echo "gh: notice: rate limit at 50%" >&2
    echo '[{"number":42,"title":"Real Issue","labels":[],"createdAt":"2024-01-01T00:00:00Z"}]'
    exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    echo '{"labels":[],"body":""}'
    exit 0
fi
exit 1
GHEOF
chmod +x "$TMPDIR_TEST/gh"
STDOUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>/tmp/lri_stderr_h1.txt) && EXIT_CODE=0 || EXIT_CODE=$?
STDERR=$(cat /tmp/lri_stderr_h1.txt)
assert_exit_zero "H1: exit 0 despite gh stderr noise" "$EXIT_CODE"
assert_output_contains "H1: real issue surfaced in TSV" "$STDOUT" "#42"
assert_output_contains "H1: summary reports 1 ready" "$STDERR" "Found 1"
cleanup

# H2: --repo missing value -> exit 2
echo "=== H2: --repo missing value -> exit 2 ==="
STDERR_OUT=$("$LIST_READY" --repo 2>&1 1>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_two "H2: --repo missing value exit 2" "$EXIT_CODE"
assert_output_contains "H2: stderr mentions --repo or usage" "$STDERR_OUT" "repo"

# H3: --label missing value -> exit 2
echo "=== H3: --label missing value -> exit 2 ==="
STDERR_OUT=$("$LIST_READY" --label 2>&1 1>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_two "H3: --label missing value exit 2" "$EXIT_CODE"
assert_output_contains "H3: stderr mentions --label or usage" "$STDERR_OUT" "label"

# H4: --limit missing value -> exit 2
echo "=== H4: --limit missing value -> exit 2 ==="
STDERR_OUT=$("$LIST_READY" --limit 2>&1 1>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_two "H4: --limit missing value exit 2" "$EXIT_CODE"
assert_output_contains "H4: stderr mentions --limit or usage" "$STDERR_OUT" "limit"

# H5: validate-issue-body --file missing value -> exit 2
echo "=== H5: validate-issue-body --file missing value -> exit 2 ==="
STDERR_OUT=$("$VALIDATE" --file 2>&1 1>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_two "H5: --file missing value exit 2" "$EXIT_CODE"
assert_output_contains "H5: stderr mentions --file or usage" "$STDERR_OUT" "file"

# H6: TSV title with embedded tab -> sanitised (exactly 2 fields)
echo "=== H6: TSV title with embedded tab -> sanitised ==="
TMPDIR_TEST=$(mktemp -d)
ALL_JSON='[{"number":10,"title":"Title	with	tabs","labels":[],"createdAt":"2024-01-01T00:00:00Z"}]'
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_10.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
STDOUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "H6: exit 0" "$EXIT_CODE"
assert_line_count "H6: exactly 1 line of output" "$STDOUT" 1
FIELD_COUNT=$(echo "$STDOUT" | awk -F'	' '{print NF}')
if [ "$FIELD_COUNT" = "2" ]; then
    echo "PASS: H6: exactly 2 tab-separated fields"
    PASS=$((PASS + 1))
else
    echo "FAIL: H6: expected 2 tab-separated fields, got $FIELD_COUNT"
    FAIL=$((FAIL + 1))
fi
cleanup

# H7: TSV title with embedded newline -> single line
echo "=== H7: TSV title with embedded newline -> single line ==="
TMPDIR_TEST=$(mktemp -d)
# Title contains a real newline in the JSON string
ALL_JSON='[{"number":11,"title":"Line one\nLine two","labels":[],"createdAt":"2024-01-01T00:00:00Z"}]'
echo '{"labels":[],"body":""}' > "$TMPDIR_TEST/issue_json_11.txt"
write_mock_gh_for_lri "$TMPDIR_TEST" "$ALL_JSON" ""
STDOUT=$(PATH="$TMPDIR_TEST:$PATH" "$LIST_READY" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "H7: exit 0" "$EXIT_CODE"
assert_line_count "H7: exactly 1 line of output" "$STDOUT" 1
cleanup

# H8: hex color #123456 should NOT trigger validator warning (exit 0)
echo "=== H8: hex color #123456 -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nUse hex color #123456 for the badge.\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "H8: hex color #123456: exit 0" "$EXIT_CODE"
cleanup

# H9: ref inside ``` fenced code block -> exit 0
echo "=== H9: ref inside fenced code block -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nWorking on it.\n\n```\ngit show #123\n```\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "H9: fenced code-block ref: exit 0" "$EXIT_CODE"
cleanup

# H10: #123abc (digits-then-alpha) should NOT trigger warning (exit 0)
echo "=== H10: #123abc -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nThe identifier is #123abc not an issue.\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "H10: #123abc identifier: exit 0" "$EXIT_CODE"
cleanup

# H11: ref inside ~~~ fenced code block -> exit 0
echo "=== H11: ref inside ~~~ fenced block -> exit 0 ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nLook at this snippet.\n\n~~~\nrelates to #456\n~~~\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "H11: ~~~ fenced block ref: exit 0" "$EXIT_CODE"
cleanup

# H12: real ref with period suffix '#42.' still triggers warning (exit 1)
echo "=== H12: regression — '#42.' still triggers warning ==="
TMPDIR_TEST=$(mktemp -d)
printf '## Description\nThis builds on #42. It is needed.\n' > "$TMPDIR_TEST/body.md"
"$VALIDATE" --file "$TMPDIR_TEST/body.md" --quiet && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "H12: '#42.' still flagged: exit 1" "$EXIT_CODE"
cleanup

# ============================================================
# Summary
# ============================================================

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
