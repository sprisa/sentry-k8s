set -euo pipefail

CHART=${CHART:-sentry-k8s}
NAMESPACE=${NAMESPACE:-sentry}
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || realpath "$(dirname "$0")/..")
RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT
TEST_CHART_DIR="$RENDER_DIR/chart"
mkdir -p "$TEST_CHART_DIR"
# Keep the source checkout immutable so this script is safe alongside the other
# parallel `task test` checks.
tar -C "$REPO_ROOT" --exclude=.git -cf - . | tar -C "$TEST_CHART_DIR" -xf -
CHART_FILE="$TEST_CHART_DIR/Chart.yaml"

INFO() { echo "--- $*"; }
PASS() { echo "  PASS  $*"; }
FAIL() { echo "  FAIL  $*"; fail=1; }
fail=0

set_appver() {
  node - "$CHART_FILE" "$1" <<'NODE'
const fs = require("node:fs");

const [chartFile, version] = process.argv.slice(2);
const contents = fs.readFileSync(chartFile, "utf8");
if (!/^appVersion:.*$/m.test(contents)) {
  throw new Error("appVersion not found in Chart.yaml");
}
const updated = contents.replace(/^appVersion:.*$/m, `appVersion: "${version}"`);
fs.writeFileSync(chartFile, updated);
NODE
}

render() {
  local appver="$1" label="$2"
  local saved_ver
  saved_ver=$(grep '^appVersion:' "$CHART_FILE" | awk '{print $2}' | tr -d '"')
  set_appver "$appver"
  for preset in errors-only errors-transactions feature-complete; do
    helm template "$CHART" "$TEST_CHART_DIR" -n "$NAMESPACE" \
      -f "$TEST_CHART_DIR/examples/values-${preset}.yaml" \
      2>"$RENDER_DIR/${label}_${preset}.stderr" \
      > "$RENDER_DIR/${label}_${preset}.yaml"
    if [ -s "$RENDER_DIR/${label}_${preset}.stderr" ]; then
      FAIL "helm template $label/$preset"
      cat "$RENDER_DIR/${label}_${preset}.stderr"
      set_appver "$saved_ver"
      return 1
    fi
  done
  set_appver "$saved_ver"
}

# Check whole-file grep counts
check() {
  local file="$1" label="$2" pattern="$3" expected="$4"
  local count
  count=$(grep -c -e "$pattern" "$file" 2>/dev/null || true)
  if [ "$count" -ne "$expected" ]; then
    FAIL "$label: expected $expected, got $count (pattern: $pattern)"
  else
    PASS "$label ($count)"
  fi
}

# Check pattern is absent from whole file
absent() {
  local file="$1" label="$2" pattern="$3"
  if grep -q -e "$pattern" "$file" 2>/dev/null; then
    FAIL "$label: found unexpectedly (pattern: $pattern)"
  else
    PASS "$label"
  fi
}

# Check that a specific consumer subcommand (like "rust-consumer" or "run consumer")
# is immediately followed by --max-poll-interval-ms within the next N lines.
# This verifies the flag is attached to the right workload.
consumer_has_flag() {
  local file="$1" label="$2" consumer_pattern="$3"
  local ctx
  ctx=$(grep -A 30 -e "$consumer_pattern" "$file" 2>/dev/null)
  if [ -z "$ctx" ]; then
    FAIL "$label: no match for '$consumer_pattern' in file ($(wc -l < "$file") lines)"
    return
  fi
  if grep -q -e "--max-poll-interval-ms" <<<"$ctx"; then
    PASS "$label"
  else
    FAIL "$label: '$consumer_pattern' matched but no --max-poll-interval-ms in context"
  fi
}
consumer_lacks_flag() {
  local file="$1" label="$2" consumer_pattern="$3"
  local ctx
  ctx=$(grep -A 30 -e "$consumer_pattern" "$file" 2>/dev/null)
  if grep -q -e "--max-poll-interval-ms" <<<"$ctx"; then
    FAIL "$label: $consumer_pattern unexpectedly has --max-poll-interval-ms"
  else
    PASS "$label"
  fi
}

# ----- OLD VERSION (26.5.2) -----
INFO "Version-gate checks: appVersion < 26.6.0"
render "26.5.2" "old"
FC="$RENDER_DIR/old_feature-complete.yaml"
EO="$RENDER_DIR/old_errors-only.yaml"

# Taskbroker uses old env vars, no new address, no -c in command
check   "$FC" "taskbroker: old TASKBROKER_KAFKA_CLUSTER"              "TASKBROKER_KAFKA_CLUSTER$" 1
check   "$FC" "taskbroker: old TASKBROKER_KAFKA_DEADLETTER_CLUSTER"   "TASKBROKER_KAFKA_DEADLETTER_CLUSTER" 1
absent  "$FC" "taskbroker: no new CLUSTERS__DEFAULT__ADDRESS"         "TASKBROKER_KAFKA_CLUSTERS__DEFAULT__ADDRESS"
check   "$EO" "taskbroker (EO): old env vars"                         "TASKBROKER_KAFKA_CLUSTER$" 1

# Replacer: no --health-check-file (grep for `replacer` arg followed by health check within context)
consumer_lacks_flag "$FC" "replacer: no --health-check-file" "^[[:space:]]*- replacer$"

# No --max-poll-interval-ms anywhere
absent "$FC" "no --max-poll-interval-ms in old render" "--max-poll-interval-ms"

# subscriptions-scheduler-executor never gets the flag
consumer_lacks_flag "$FC" "subscriptions-scheduler-executor clean" "^[[:space:]]*- subscriptions-scheduler-executor"

echo ""
# ----- NEW VERSION (26.6.0) -----
INFO "Version-gate checks: appVersion >= 26.6.0"
render "26.6.0" "new"
FC="$RENDER_DIR/new_feature-complete.yaml"
EO="$RENDER_DIR/new_errors-only.yaml"

# Taskbroker uses new env var, no old cluster, has -c command
check   "$FC" "taskbroker: new CLUSTERS__DEFAULT__ADDRESS"            "TASKBROKER_KAFKA_CLUSTERS__DEFAULT__ADDRESS" 1
absent  "$FC" "taskbroker: no old CLUSTER"                            "TASKBROKER_KAFKA_CLUSTER$"
check   "$FC" "taskbroker: -c in command"                              'command: \["/opt/taskbroker", "-c"' 1
check   "$EO" "taskbroker (EO): new env var"                          "TASKBROKER_KAFKA_CLUSTERS__DEFAULT__ADDRESS" 1
check   "$EO" "legacy Sentry events subscription consumer"             "events-subscription-results" 1

# Replacer: has --health-check-file and --max-poll-interval-ms
consumer_has_flag "$FC" "replacer: --health-check-file"               "^[[:space:]]*- replacer$"
# Verify health-check-file is specifically in the replacer args
check "$FC" "replacer: --health-check-file count"                     "--health-check-file" 26
# Sanity: count includes the replacer (one of the 26)

# Spot-check that --max-poll-interval-ms appears near consumers
consumer_has_flag "$FC" "rust-consumer: flag present"                 "^[[:space:]]*- rust-consumer$"
# run consumer check: in the rendered args, `run` is a separate arg from `consumer`
consumer_has_flag "$FC" "run consumer: flag present"                  "^[[:space:]]*- run$"

# Env var is present
check "$FC" "SENTRY_KAFKA_MAX_POLL_INTERVAL_MS env var"              "SENTRY_KAFKA_MAX_POLL_INTERVAL_MS" 58

# subscriptions-scheduler-executor must NOT get the flag
consumer_lacks_flag "$FC" "subscriptions-scheduler-executor clean"    "^[[:space:]]*- subscriptions-scheduler-executor"

echo ""
# ----- SUBSCRIPTION CONSUMER LAYOUT (26.7.0+) -----
INFO "Version-gate checks: appVersion >= 26.7.0"
render "26.7.2" "subscription-layout"
FC="$RENDER_DIR/subscription-layout_feature-complete.yaml"
EO="$RENDER_DIR/subscription-layout_errors-only.yaml"

# Sentry 26.7.0 removed the legacy Sentry subscription-result consumers. The
# equivalent work is handled by Snuba subscriptions-scheduler-executor pods.
absent "$FC" "no legacy Sentry events subscription consumer"             "events-subscription-results"
absent "$FC" "no legacy Sentry transactions subscription consumer"       "transactions-subscription-results"
absent "$FC" "no legacy Sentry metrics subscription consumer"            "metrics-subscription-results"
absent "$FC" "no legacy Sentry generic metrics subscription consumer"     "generic-metrics-subscription-results"
absent "$FC" "no legacy Sentry EAP subscription consumer"                 "subscription-results-eap-items"
check  "$EO" "Snuba events subscription consumer remains"                "snuba-events-subscriptions-consumers" 1
check  "$FC" "Snuba transactions subscription consumer remains"           "snuba-transactions-subscriptions-consumers" 1
check  "$FC" "Snuba metrics subscription consumer remains"                "snuba-metrics-subscriptions-consumers" 1
check  "$FC" "Snuba generic metrics distributions consumer remains"       "snuba-generic-metrics-distributions-subscriptions-schedulers" 1
check  "$FC" "Snuba generic metrics sets consumer remains"                "snuba-generic-metrics-sets-subscriptions-schedulers" 1
check  "$FC" "Snuba generic metrics counters consumer remains"             "snuba-generic-metrics-counters-subscriptions-schedulers" 1
check  "$FC" "Snuba generic metrics gauges consumer remains"               "snuba-generic-metrics-gauges-subscriptions-schedulers" 1
check  "$FC" "Snuba EAP subscription consumer remains"                     "snuba-eap-items-subscriptions-consumers" 1

echo ""
if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail check(s) failed."
  exit 1
fi
echo "All version-gate checks passed."
