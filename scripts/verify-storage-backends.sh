#!/usr/bin/env bash
# Render-contract checks for independent S3 storage backends.
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
  local output="$1"
  shift
  if helm template "$CHART" "$REPO_ROOT" -n "$NAMESPACE" "$@" >"$output" 2>"$output.stderr"; then
    return
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

echo "--- Storage backend render checks"

nodestore="$RENDER_DIR/nodestore.yaml"
render "$nodestore" \
  --set nodestore.backend=s3 \
  --set nodestore.s3.existingSecret=sentry-r2 \
  --set nodestore.s3.bucketName=sentry-nodestore \
  --set nodestore.s3.endpointUrl=https://account.r2.cloudflarestorage.com \
  --set nodestore.s3.region_name=auto
expect_present "$nodestore" "nodestore S3 backend renders" "SENTRY_NODESTORE = \"sentry_nodestore_s3.S3PassthroughDjangoNodeStorage\""
expect_present "$nodestore" "nodestore installs S3 package" "sentry-nodestore-s3"
expect_present "$nodestore" "nodestore uses existing Secret" "name: sentry-r2"
expect_present "$nodestore" "nodestore Secret access key" "key: AWS_ACCESS_KEY_ID"
expect_present "$nodestore" "nodestore Secret secret key" "key: AWS_SECRET_ACCESS_KEY"
expect_absent "$nodestore" "nodestore-only leaves filestore filesystem" "filestore.backend: 's3'"

inline="$RENDER_DIR/inline.yaml"
render "$inline" \
  --set nodestore.backend=s3 \
  --set-string nodestore.s3.accessKey=nodestore-access \
  --set-string nodestore.s3.secretKey=nodestore-secret
expect_present "$inline" "nodestore inline access key" 'value: "nodestore-access"'
expect_present "$inline" "nodestore inline secret key" 'value: "nodestore-secret"'

disabled="$RENDER_DIR/disabled.yaml"
render "$disabled"
expect_absent "$disabled" "default backend has no S3 nodestore" "SENTRY_NODESTORE = \"sentry_nodestore_s3"
expect_absent "$disabled" "default backend has no AWS credentials" "AWS_ACCESS_KEY_ID"

if [ "$fail" -ne 0 ]; then
  echo "Storage backend checks failed." >&2
  exit 1
fi

echo "Storage backend checks passed."
