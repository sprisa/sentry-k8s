#!/usr/bin/env bash
# Render-contract and schema checks for Kafka/Relay self-remediation.
set -euo pipefail

CHART=${CHART:-sentry-k8s}
NAMESPACE=${NAMESPACE:-sentry}
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || realpath "$(dirname "$0")/..")
RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

fail=0

pass() { echo "  PASS $*"; }
fail_check() { echo "  FAIL $*" >&2; fail=1; }

render() {
  local output="$1" raw="$1.raw"
  shift
  if helm template "$CHART" "$REPO_ROOT" -n "$NAMESPACE" "$@" >"$raw" 2>"$output.stderr"; then
    awk '
      /^---$/ {
        if (keep) print document
        document = $0 ORS
        keep = 0
        next
      }
      {
        document = document $0 ORS
        if ($0 == "# Source: sentry-k8s/templates/kafka/statefulset.yaml" ||
            $0 == "# Source: sentry-k8s/templates/sentry/relay.yaml") keep = 1
      }
      END { if (keep) print document }
    ' "$raw" >"$output"
    return 0
  fi
  fail_check "render $(basename "$output")"
  <"$output.stderr" tr -d '\r' >&2
}

expect_present() {
  local file="$1" label="$2" pattern="$3"
  if grep -q -- "$pattern" "$file"; then pass "$label"; else fail_check "$label: missing $pattern"; fi
}

expect_absent() {
  local file="$1" label="$2" pattern="$3"
  if grep -q -- "$pattern" "$file"; then fail_check "$label: unexpectedly found $pattern"; else pass "$label"; fi
}

expect_count() {
  local file="$1" label="$2" pattern="$3" expected="$4" count
  count=$(grep -c -- "$pattern" "$file" || true)
  if [ "$count" -eq "$expected" ]; then pass "$label ($count)"; else fail_check "$label: expected $expected, got $count"; fi
}

expect_failure() {
  local label="$1"
  shift
  if helm template "$CHART" "$REPO_ROOT" -n "$NAMESPACE" "$@" >/dev/null 2>&1; then
    fail_check "$label: expected failure"
  else
    pass "$label"
  fi
}

echo "--- Kafka and Relay recovery render checks"

single="$RENDER_DIR/single.yaml"
render "$single"
expect_count "$single" "single broker has three semantic probes" "--unavailable-partitions" 3
expect_present "$single" "single broker has startup probe" "startupProbe:"
expect_present "$single" "probe JVM heap is constrained" 'KAFKA_HEAP_OPTS="-Xms32m -Xmx64m"'
expect_present "$single" "Relay receives BusyBox probe tools" "cp /bin/busybox /probe/busybox"
expect_present "$single" "Relay readiness checks ready endpoint" "/api/relay/healthcheck/ready/"
expect_present "$single" "Relay probes readiness-gated Kafka Service" "nc -z -w 3 sentry-k8s-kafka 9092"
expect_present "$single" "Relay records a Kafka outage" "touch /probe-state/kafka-unavailable"
expect_present "$single" "Relay liveness honors the outage marker" "test ! -e /probe-state/kafka-unavailable"
expect_present "$single" "Relay clears the marker after restart" 'command: ["/probe/busybox", "rm", "-f", "/probe-state/kafka-unavailable"]'
expect_present "$single" "topic validation renders safe default" "kafka_validate_topics: false"
expect_present "$single" "librdkafka rebootstrap renders" 'name: "metadata.recovery.strategy", value: "rebootstrap"'
expect_present "$single" "metadata refresh renders" 'name: "topic.metadata.refresh.interval.ms", value: 30000'

ha="$RENDER_DIR/ha.yaml"
render "$ha" --set kafka.replicas=3 --set kafka.replicationFactor=3 --set kafka.minInsyncReplicas=2
expect_absent "$ha" "HA avoids cluster-wide semantic probes" "--unavailable-partitions"
expect_absent "$ha" "HA avoids semantic startup probe" "startupProbe:"
expect_count "$ha" "HA retains Kafka TCP readiness and liveness" "tcpSocket:" 2
expect_absent "$ha" "HA auto mode retains native Relay probes" "cp /bin/busybox /probe/busybox"
expect_present "$ha" "HA Relay liveness remains HTTP" "httpGet:"

external="$RENDER_DIR/external.yaml"
render "$external" --set kafka.enabled=false --set 'externalKafka.brokers[0].host=kafka.example' --set 'externalKafka.brokers[0].port=9092'
expect_absent "$external" "external Kafka has no bundled StatefulSet" "kind: StatefulSet"
expect_absent "$external" "external Kafka has no semantic command" "--unavailable-partitions"
expect_absent "$external" "external Kafka does not auto-couple Relay" "cp /bin/busybox /probe/busybox"
expect_present "$external" "external bootstrap still configures Relay" 'value: "kafka.example:9092"'

disabled="$RENDER_DIR/disabled.yaml"
render "$disabled" --set kafka.enabled=false --set relay.enabled=false
expect_absent "$disabled" "disabled bundled Kafka renders no StatefulSet" "kind: StatefulSet"
expect_absent "$disabled" "disabled Relay renders no coupling" "relay-probe-tools"

overrides="$RENDER_DIR/overrides.yaml"
render "$overrides" \
  --set kafka.semanticProbes.mode=tcp \
  --set relay.kafka.healthProbes.mode=disabled \
  --set relay.kafka.validateTopics=true \
  --set relay.kafka.metadataRecoveryStrategy=none \
  --set relay.kafka.metadataRecoveryRebootstrapTriggerMs=45000 \
  --set relay.kafka.topicMetadataRefreshIntervalMs=60000 \
  --set relay.kafka.metadataMaxAgeMs=120000
expect_absent "$overrides" "TCP override disables Kafka semantic probes" "--unavailable-partitions"
expect_count "$overrides" "TCP override restores both probes" "tcpSocket:" 2
expect_absent "$overrides" "Relay coupling can be disabled" "cp /bin/busybox /probe/busybox"
expect_present "$overrides" "topic validation override renders" "kafka_validate_topics: true"
expect_present "$overrides" "recovery strategy override renders" 'name: "metadata.recovery.strategy", value: "none"'
expect_present "$overrides" "metadata age override renders" 'name: "metadata.max.age.ms", value: 120000'

timings="$RENDER_DIR/timings.yaml"
render "$timings" \
  --set-string kafka.semanticProbes.heapOpts='-Xms24m -Xmx48m' \
  --set kafka.semanticProbes.startup.failureThreshold=44 \
  --set relay.kafka.healthProbes.liveness.failureThreshold=12
expect_present "$timings" "Kafka heap override renders" 'KAFKA_HEAP_OPTS="-Xms24m -Xmx48m"'
expect_present "$timings" "Kafka timing override renders" "failureThreshold: 44"
expect_present "$timings" "Relay timing override renders" "failureThreshold: 12"

expect_failure "invalid Kafka probe mode rejected by schema" --set kafka.semanticProbes.mode=invalid
expect_failure "zero Kafka timeout rejected by schema" --set kafka.semanticProbes.readiness.timeoutSeconds=0
expect_failure "invalid liveness success threshold rejected" --set kafka.semanticProbes.liveness.successThreshold=2
expect_failure "invalid Relay health mode rejected by schema" --set relay.kafka.healthProbes.mode=invalid
expect_failure "invalid recovery strategy rejected by schema" --set relay.kafka.metadataRecoveryStrategy=invalid
expect_failure "semantic probes rejected for HA" --set kafka.replicas=3 --set kafka.semanticProbes.mode=semantic

if [ "$fail" -ne 0 ]; then
  echo "Kafka and Relay recovery checks failed." >&2
  exit 1
fi

echo "Kafka and Relay recovery checks passed."
