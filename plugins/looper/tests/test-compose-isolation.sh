#!/usr/bin/env bash
set -euo pipefail

# test-compose-isolation.sh — Verify docker-compose isolation infrastructure:
# 1. detect-compose outputs correct JSON for compose/no-compose projects
# 2. compose-isolate generates valid override and env files
# 3. detect-stack includes has_compose field
# 4. Agent prompts reference compose lifecycle
# 5. SKILL.md references compose isolation step

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/skills/looper/scripts"
AGENTS_DIR="$REPO_ROOT/agents"
SKILL_FILE="$REPO_ROOT/skills/looper/SKILL.md"

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

for script in detect-compose compose-isolate compose-lifecycle; do
    check "$script exists" \
        "$([ -f "$SCRIPTS_DIR/$script" ] && echo true || echo false)"
    check "$script is executable" \
        "$([ -x "$SCRIPTS_DIR/$script" ] && echo true || echo false)"
done

# --- detect-compose: no compose file ---

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
mkdir -p no-compose && cd no-compose

output=$("$SCRIPTS_DIR/detect-compose" 2>/dev/null)
compose_file=$(echo "$output" | jq -r '.compose_file')
check "detect-compose: no compose file returns none" \
    "$([ "$compose_file" = "none" ] && echo true || echo false)"

cd "$TMPDIR"

# --- detect-compose: with compose file ---

mkdir -p with-compose && cd with-compose
cat > docker-compose.yml << 'EOF'
services:
  db:
    image: postgres:16
    ports:
      - "5432:5432"
  cache:
    image: redis:7
    ports:
      - "6379:6379"
  web:
    build: .
    ports:
      - "3000:3000"
EOF
# Need a minimal Dockerfile for docker compose config to work
echo "FROM node:20" > Dockerfile

output=$("$SCRIPTS_DIR/detect-compose" 2>/dev/null)
compose_file=$(echo "$output" | jq -r '.compose_file')
num_services=$(echo "$output" | jq '.services | length')
db_image=$(echo "$output" | jq -r '.services.db.image')
web_has_build=$(echo "$output" | jq -r '.services.web.has_build')
db_host_port=$(echo "$output" | jq -r '.services.db.ports[0].host')

check "detect-compose: finds docker-compose.yml" \
    "$([ "$compose_file" = "docker-compose.yml" ] && echo true || echo false)"
check "detect-compose: finds 3 services" \
    "$([ "$num_services" = "3" ] && echo true || echo false)"
check "detect-compose: extracts postgres image" \
    "$(echo "$db_image" | grep -q "postgres" && echo true || echo false)"
check "detect-compose: detects build context on web service" \
    "$([ "$web_has_build" = "true" ] && echo true || echo false)"
check "detect-compose: extracts host port 5432 for db" \
    "$([ "$db_host_port" = "5432" ] && echo true || echo false)"

# --- compose-isolate: generates override and env ---

isolate_output=$("$SCRIPTS_DIR/compose-isolate" --task "test-compose" 2>/dev/null)
status=$(echo "$isolate_output" | jq -r '.status')

check "compose-isolate: returns isolated status" \
    "$([ "$status" = "isolated" ] && echo true || echo false)"

# Check override file exists and has valid structure
check "compose-isolate: creates docker-compose.looper.yml" \
    "$([ -f "docker-compose.looper.yml" ] && echo true || echo false)"

if [ -f "docker-compose.looper.yml" ]; then
    # Override should have db and cache services (not web — it has build context)
    check "compose-isolate: override contains db service" \
        "$(grep -q "db:" docker-compose.looper.yml && echo true || echo false)"
    check "compose-isolate: override contains cache service" \
        "$(grep -q "cache:" docker-compose.looper.yml && echo true || echo false)"
    check "compose-isolate: override excludes web (build) service" \
        "$(! grep -q "web:" docker-compose.looper.yml && echo true || echo false)"

    # Ports should be remapped (not the original 5432/6379)
    check "compose-isolate: postgres port is remapped (not 5432)" \
        "$(! grep -q '"5432:5432"' docker-compose.looper.yml && echo true || echo false)"
    check "compose-isolate: redis port is remapped (not 6379)" \
        "$(! grep -q '"6379:6379"' docker-compose.looper.yml && echo true || echo false)"
fi

# Check env file exists and has connection strings
check "compose-isolate: creates .env.looper" \
    "$([ -f ".env.looper" ] && echo true || echo false)"

if [ -f ".env.looper" ]; then
    check "compose-isolate: env has COMPOSE_PROJECT_NAME" \
        "$(grep -q 'COMPOSE_PROJECT_NAME=looper-test-compose' .env.looper && echo true || echo false)"
    check "compose-isolate: env has DATABASE_URL" \
        "$(grep -q 'DATABASE_URL=' .env.looper && echo true || echo false)"
    check "compose-isolate: env has REDIS_URL" \
        "$(grep -q 'REDIS_URL=' .env.looper && echo true || echo false)"
    check "compose-isolate: env has PGPORT" \
        "$(grep -q 'PGPORT=' .env.looper && echo true || echo false)"

    # Verify remapped ports in env match the override
    env_pgport=$(grep 'PGPORT=' .env.looper | cut -d= -f2)
    check "compose-isolate: PGPORT is in isolated range (10000-60000)" \
        "$([ "$env_pgport" -ge 10000 ] && [ "$env_pgport" -le 60000 ] && echo true || echo false)"
fi

# --- compose-isolate: deterministic ports ---

"$SCRIPTS_DIR/compose-isolate" --task "test-compose" > /dev/null 2>/dev/null
pgport1=$(grep 'PGPORT=' .env.looper | cut -d= -f2)
"$SCRIPTS_DIR/compose-isolate" --task "test-compose" > /dev/null 2>/dev/null
pgport2=$(grep 'PGPORT=' .env.looper | cut -d= -f2)

check "compose-isolate: same task produces same ports (deterministic)" \
    "$([ "$pgport1" = "$pgport2" ] && echo true || echo false)"

# Different task should produce different ports
"$SCRIPTS_DIR/compose-isolate" --task "other-task" > /dev/null 2>/dev/null
pgport3=$(grep 'PGPORT=' .env.looper | cut -d= -f2)

check "compose-isolate: different task produces different ports" \
    "$([ "$pgport1" != "$pgport3" ] && echo true || echo false)"

cd "$REPO_ROOT"

# --- detect-stack: has_compose field ---

check_file_contains "detect-stack outputs has_compose field" \
    "$SCRIPTS_DIR/detect-stack" \
    "has_compose"

check_file_contains "detect-stack outputs compose_file field" \
    "$SCRIPTS_DIR/detect-stack" \
    "compose_file"

# --- _helpers.sh: compose functions ---

check_file_contains "_helpers.sh has has_compose function" \
    "$SCRIPTS_DIR/_helpers.sh" \
    "has_compose()"

check_file_contains "_helpers.sh has compose_cmd function" \
    "$SCRIPTS_DIR/_helpers.sh" \
    "compose_cmd()"

check_file_contains "_helpers.sh has load_compose_env function" \
    "$SCRIPTS_DIR/_helpers.sh" \
    "load_compose_env()"

# --- Agent prompts reference compose ---

check_file_contains "planner.md references compose-lifecycle" \
    "$AGENTS_DIR/planner.md" \
    "compose-lifecycle"

check_file_contains "doer.md references compose" \
    "$AGENTS_DIR/doer.md" \
    "HAS_COMPOSE"

check_file_contains "checker.md references compose-lifecycle" \
    "$AGENTS_DIR/checker.md" \
    "compose-lifecycle"

# --- SKILL.md references compose isolation ---

check_file_contains "SKILL.md has step 7b2 for compose isolation" \
    "$SKILL_FILE" \
    "compose-isolate"

check_file_contains "SKILL.md passes HAS_COMPOSE to agents" \
    "$SKILL_FILE" \
    "HAS_COMPOSE"

check_file_contains "SKILL.md passes COMPOSE_SERVICES to agents" \
    "$SKILL_FILE" \
    "COMPOSE_SERVICES"

# --- run-integration-tests: compose support ---

check_file_contains "run-integration-tests checks has_compose" \
    "$SCRIPTS_DIR/run-integration-tests" \
    "use_compose"

check_file_contains "run-integration-tests calls compose-lifecycle" \
    "$SCRIPTS_DIR/run-integration-tests" \
    "compose-lifecycle"

# --- scaffold-integration-ci: compose support ---

check_file_contains "scaffold-integration-ci checks use_compose" \
    "$SCRIPTS_DIR/scaffold-integration-ci" \
    "use_compose"

check_file_contains "scaffold-integration-ci adds compose up step" \
    "$SCRIPTS_DIR/scaffold-integration-ci" \
    "Start backing services"

check_file_contains "scaffold-integration-ci adds compose down step" \
    "$SCRIPTS_DIR/scaffold-integration-ci" \
    "Stop backing services"

# --- Summary ---

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
