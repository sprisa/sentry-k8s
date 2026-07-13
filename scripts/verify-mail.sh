#!/usr/bin/env bash
# Render-contract checks for SMTP credential handling.
set -euo pipefail

CHART=${CHART:-sentry-k8s}
NAMESPACE=${NAMESPACE:-sentry}
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || realpath "$(dirname "$0")/..")
RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

fail=0

pass() {
  echo "  PASS $*"
}

fail_check() {
  echo "  FAIL $*" >&2
  fail=1
}

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
  if grep -q -- "$pattern" "$file"; then
    pass "$label"
  else
    fail_check "$label: missing $pattern"
  fi
}

expect_absent() {
  local file="$1" label="$2" pattern="$3"
  if grep -q -- "$pattern" "$file"; then
    fail_check "$label: unexpectedly found $pattern"
  else
    pass "$label"
  fi
}

expect_same_count() {
  local file="$1" label="$2" left="$3" right="$4"
  local left_count right_count
  left_count=$(grep -c -- "$left" "$file" || true)
  right_count=$(grep -c -- "$right" "$file" || true)
  if [ "$left_count" -eq "$right_count" ]; then
    pass "$label ($left_count)"
  else
    fail_check "$label: $left_count != $right_count"
  fi
}

expect_failure() {
  local label="$1"
  shift
  if helm template "$CHART" "$REPO_ROOT" -n "$NAMESPACE" "$@" >/dev/null 2>&1; then
    fail_check "$label: expected template failure"
  else
    pass "$label"
  fi
}

config_map() {
  awk '
    /^---$/ {
      if (target) {
        print document
        exit
      }
      document = $0 ORS
      target = 0
      next
    }
    {
      document = document $0 ORS
      if ($0 == "    app.kubernetes.io/component: sentry-config") {
        target = 1
      }
    }
    END {
      if (target) {
        print document
      }
    }
  ' "$1"
}

echo "--- Mail render checks"

external="$RENDER_DIR/external.yaml"
render "$external" \
  --set mail.enabled=true \
  --set mail.host=smtp.example.com \
  --set mail.port=587 \
  --set mail.existingSecret=sentry-smtp \
  --set mail.existingSecretUsernameKey=ses-username \
  --set mail.existingSecretPasswordKey=ses-password \
  --set mail.useTls=true \
  --set mail.useSsl=false \
  --set mail.from=alerts@example.com

expect_present "$external" "external Secret username env" "name: SENTRY_MAIL_USERNAME"
expect_present "$external" "external Secret password env" "name: SENTRY_MAIL_PASSWORD"
expect_present "$external" "external Secret name" "name: sentry-smtp"
expect_present "$external" "external Secret username key" "key: ses-username"
expect_present "$external" "external Secret password key" "key: ses-password"
expect_same_count "$external" "all Sentry workloads receive username" "name: SENTRY_CONF" "name: SENTRY_MAIL_USERNAME"
expect_same_count "$external" "all Sentry workloads receive password" "name: SENTRY_CONF" "name: SENTRY_MAIL_PASSWORD"

external_config="$RENDER_DIR/external-configmap.yaml"
config_map "$external" >"$external_config"
expect_present "$external_config" "explicit sender retained" 'mail.from: "alerts@example.com"'
expect_absent "$external_config" "host-derived sender omitted" 'SENTRY_OPTIONS\["mail.from"\] = f"sentry@'
expect_absent "$external_config" "external username absent from ConfigMap" "ses-username"
expect_absent "$external_config" "external password absent from ConfigMap" "ses-password"

inline="$RENDER_DIR/inline.yaml"
render "$inline" \
  --set mail.enabled=true \
  --set mail.host=smtp.example.com \
  --set mail.username=inline-user \
  --set mail.password=inline-password \
  --set mail.useTls=true \
  --set mail.useSsl=false

expect_present "$inline" "inline credentials use dedicated Secret" "name: sentry-k8s-mail"
expect_present "$inline" "inline username stored in Secret" "username: \"$(printf '%s' inline-user | base64)\""
expect_present "$inline" "inline password stored in Secret" "password: \"$(printf '%s' inline-password | base64)\""
inline_config="$RENDER_DIR/inline-configmap.yaml"
config_map "$inline" >"$inline_config"
expect_absent "$inline_config" "inline username absent from ConfigMap" "inline-user"
expect_absent "$inline_config" "inline password absent from ConfigMap" "inline-password"

disabled="$RENDER_DIR/disabled.yaml"
render "$disabled"
expect_absent "$disabled" "disabled mail has no username env" "SENTRY_MAIL_USERNAME"
expect_absent "$disabled" "disabled mail has no password env" "SENTRY_MAIL_PASSWORD"
expect_absent "$disabled" "disabled mail has no dedicated Secret" "app.kubernetes.io/component: mail"

expect_failure "mail host required" --set mail.enabled=true
expect_failure "mail TLS and SSL conflict" \
  --set mail.enabled=true --set mail.host=smtp.example.com \
  --set mail.useTls=true --set mail.useSsl=true
expect_failure "mail username requires password" \
  --set mail.enabled=true --set mail.host=smtp.example.com --set mail.username=user
expect_failure "mail password requires username" \
  --set mail.enabled=true --set mail.host=smtp.example.com --set mail.password=password
expect_failure "mail Secret and inline credentials conflict" \
  --set mail.enabled=true --set mail.host=smtp.example.com \
  --set mail.existingSecret=sentry-smtp --set mail.username=user --set mail.password=password

if [ "$fail" -ne 0 ]; then
  echo "Mail render checks failed." >&2
  exit 1
fi

echo "Mail render checks passed."
