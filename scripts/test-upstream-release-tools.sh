#!/usr/bin/env bash
# Unit-style tests for the local upstream release automation helpers.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || realpath "$(dirname "$0")/..")
BUMP="$REPO_ROOT/scripts/bump-appversion.sh"
REPORT="$REPO_ROOT/scripts/build-upstream-pr-report.mjs"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

failed=0

pass() {
  echo "  PASS $*"
}

fail() {
  echo "  FAIL $*" >&2
  failed=1
}

expect_contains() {
  local file="$1" label="$2" value="$3"
  if grep -Fq -- "$value" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

expect_exit_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$label"
  else
    pass "$label"
  fi
}

chart="$WORK_DIR/Chart.yaml"
cat >"$chart" <<'EOF'
apiVersion: v2
name: sentry-k8s
version: 1.2.0
appVersion: "26.6.0"
EOF

echo "--- bump-appversion checks"
CHART_FILE="$chart" bash "$BUMP" 26.6.1 >/dev/null
expect_contains "$chart" "updates appVersion" 'appVersion: "26.6.1"'
expect_contains "$chart" "patch-bumps chart version" "version: 1.2.1"

before=$(cksum "$chart")
CHART_FILE="$chart" bash "$BUMP" 26.6.1 >/dev/null
after=$(cksum "$chart")
if [ "$before" = "$after" ]; then
  pass "already-current version is unchanged"
else
  fail "already-current version is unchanged"
fi

expect_exit_failure "rejects malformed version" env CHART_FILE="$chart" bash "$BUMP" 26.6.1-rc.1
expect_exit_failure "rejects non-forward version" env CHART_FILE="$chart" bash "$BUMP" 26.6.0

echo "--- upstream report checks"
releases="$WORK_DIR/releases.json"
cat >"$releases" <<'EOF'
[
  {
    "tag_name": "26.6.1",
    "draft": false,
    "prerelease": false,
    "html_url": "https://example.test/releases/26.6.1",
    "body": "Routine fixes."
  },
  {
    "tag_name": "26.7.0",
    "draft": false,
    "prerelease": false,
    "html_url": "https://example.test/releases/26.7.0",
    "body": "Breaking: remove deprecated setting. Manual action required."
  },
  {
    "tag_name": "26.8.0-rc.1",
    "draft": false,
    "prerelease": true,
    "html_url": "https://example.test/releases/26.8.0-rc.1",
    "body": "Pre-release."
  }
]
EOF

routine_files="$WORK_DIR/routine-files.txt"
: >"$routine_files"
routine_body="$WORK_DIR/routine.md"
routine_metadata="$WORK_DIR/routine.json"
node "$REPORT" \
  --current 26.6.0 --target 26.6.1 \
  --releases-json "$releases" --changed-files "$routine_files" \
  --body-file "$routine_body" --metadata-file "$routine_metadata"
expect_contains "$routine_body" "routine release notes included" "Routine fixes."
expect_contains "$routine_body" "routine release link included" "https://example.test/releases/26.6.1"
expect_contains "$routine_metadata" "routine release is reviewable" '"draft": false'

risk_files="$WORK_DIR/risk-files.txt"
printf '%s\n' 'nginx/nginx.conf' 'sentry/migrations/0001.py' >"$risk_files"
risk_body="$WORK_DIR/risk.md"
risk_metadata="$WORK_DIR/risk.json"
node "$REPORT" \
  --current 26.6.0 --target 26.7.0 \
  --releases-json "$releases" --changed-files "$risk_files" \
  --body-file "$risk_body" --metadata-file "$risk_metadata"
expect_contains "$risk_body" "aggregates skipped release notes" "Routine fixes."
expect_contains "$risk_body" "includes breaking signal" "breaking"
expect_contains "$risk_body" "includes sensitive nginx change" "nginx/nginx.conf"
expect_contains "$risk_metadata" "risk release is draft" '"draft": true'
expect_contains "$risk_metadata" "two releases are included" '"release_count": 2'

if [ "$failed" -ne 0 ]; then
  echo "Upstream release automation checks failed." >&2
  exit 1
fi

echo "Upstream release automation checks passed."
