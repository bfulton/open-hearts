#!/usr/bin/env bash
# The review's worker (review_worker.dart), compiled on its own and put
# beside the built app in the directory named: deploy.sh and
# e2e/build.sh both run it after `flutter build web`, which compiles
# only the app.
set -euo pipefail
out="$1"
here="$(cd "$(dirname "$0")" && pwd)"
dart="${DART:-$(dirname "$(command -v "${FLUTTER:-flutter}")")/dart}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
( cd "$here/.." && "$dart" compile js -O2 --no-source-maps -o "$tmp/review_worker.js" worker/review_worker.dart >/dev/null )
cp "$tmp/review_worker.js" "$out/review_worker.js"
