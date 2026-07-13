#!/usr/bin/env bash
# Verify that every getsentry image used by this chart has a release manifest.
# Usage: scripts/verify-upstream-images.sh <major.minor.patch>
set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "usage: $0 <major.minor.patch>" >&2
  exit 1
}

images=(
  ghcr.io/getsentry/sentry
  ghcr.io/getsentry/snuba
  ghcr.io/getsentry/relay
  ghcr.io/getsentry/symbolicator
  ghcr.io/getsentry/vroom
  ghcr.io/getsentry/taskbroker
  ghcr.io/getsentry/uptime-checker
  ghcr.io/getsentry/launchpad
)

for image in "${images[@]}"; do
  echo "Checking ${image}:${VERSION}"
  docker manifest inspect "${image}:${VERSION}" >/dev/null
done
