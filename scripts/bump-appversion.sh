#!/usr/bin/env bash
# Update Chart.yaml for a newer stable getsentry/self-hosted release.
# Usage: scripts/bump-appversion.sh <major.minor.patch>
set -euo pipefail

VERSION="${1:-}"
CHART_FILE="${CHART_FILE:-Chart.yaml}"

die() {
  echo "bump-appversion: $*" >&2
  exit 1
}

valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

version_gt() {
  local -a left right
  IFS=. read -r -a left <<<"$1"
  IFS=. read -r -a right <<<"$2"
  for index in 0 1 2; do
    if ((10#${left[index]} > 10#${right[index]})); then
      return 0
    fi
    if ((10#${left[index]} < 10#${right[index]})); then
      return 1
    fi
  done
  return 1
}

[ -n "$VERSION" ] || die "usage: $0 <major.minor.patch>"
valid_version "$VERSION" || die "version must be stable SemVer: $VERSION"
[ -f "$CHART_FILE" ] || die "Chart file not found: $CHART_FILE"

CURRENT_APP_VERSION=$(
  awk -F'"' '/^appVersion:/ { print $2; exit }' "$CHART_FILE"
)
CURRENT_CHART_VERSION=$(
  awk '/^version:/ { print $2; exit }' "$CHART_FILE"
)

valid_version "$CURRENT_APP_VERSION" ||
  die "Chart appVersion is not stable SemVer: $CURRENT_APP_VERSION"
valid_version "$CURRENT_CHART_VERSION" ||
  die "Chart version is not stable SemVer: $CURRENT_CHART_VERSION"

if [ "$VERSION" = "$CURRENT_APP_VERSION" ]; then
  echo "Already on Sentry self-hosted $VERSION."
  exit 0
fi

version_gt "$VERSION" "$CURRENT_APP_VERSION" ||
  die "refusing non-forward appVersion change: $CURRENT_APP_VERSION -> $VERSION"

IFS=. read -r chart_major chart_minor chart_patch <<<"$CURRENT_CHART_VERSION"
NEXT_CHART_VERSION="${chart_major}.${chart_minor}.$((10#$chart_patch + 1))"
tmp_file=$(mktemp "${CHART_FILE}.XXXXXX")
trap 'rm -f "$tmp_file"' EXIT

awk \
  -v app_version="$VERSION" \
  -v chart_version="$NEXT_CHART_VERSION" '
  /^version:/ { print "version: " chart_version; next }
  /^appVersion:/ { print "appVersion: \"" app_version "\""; next }
  { print }
' "$CHART_FILE" >"$tmp_file"

mv "$tmp_file" "$CHART_FILE"
trap - EXIT

echo "Updated appVersion ${CURRENT_APP_VERSION} -> ${VERSION}"
echo "Updated chart version ${CURRENT_CHART_VERSION} -> ${NEXT_CHART_VERSION}"
