#!/usr/bin/env bash
# Publish the site and the app to Cloudflare Pages.
#
# Assembles one directory and uploads it once:
#
#   /            the marketing site (site/, copied verbatim)
#   /api/        the service's handlers (service/functions/worker.mjs,
#                published as _worker.js)
#   /play/       the Flutter web build, base-href /play/
#   /measure/    benchmarks meant to be run on a phone (only the ones
#                that have been built; see measurements/README.md)
#
# Every commit publishes, which is the whole point: the phone reading
# https://dev.open-hearts.pages.dev/play is looking at the last push.
#
# Usage:  ./deploy.sh [branch-label]
#
# The label names the Pages branch, and Cloudflare gives every branch a
# stable alias URL. Default is "dev" on any working branch — a short,
# bookmarkable host that does not change as branches come and go — and
# "main" (which is production, so the custom domain) on main.
#
# Needs CLOUDFLARE_TOKEN and CLOUDFLARE_ACCOUNT_ID in the environment.
set -euo pipefail
cd "$(dirname "$0")"

PROJECT=open-hearts
FLUTTER=${FLUTTER:-flutter}
WRANGLER_VERSION=4.130.0
STAGE=build/publish

branch_of_git() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo dev
}

LABEL=${1:-}
if [ -z "$LABEL" ]; then
  LABEL=$([ "$(branch_of_git)" = main ] && echo main || echo dev)
fi

# "+" marks a dirty tree: the deploy holds work newer than the sha it
# claims. Committing first is the habit; the suffix catches the misses.
SHA=$(git rev-parse --short HEAD)
BUILD_TAG="$SHA$([ -n "$(git status --porcelain)" ] && echo '+' || true)"
BUILD_DATE=$(date -u +%Y-%m-%d)

echo "==> building $BUILD_TAG -> $LABEL"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -r site/. "$STAGE"/
# The service's handlers (docs/06-service.md) run as the Pages worker:
# _worker.js at the root of what is published answers /api/…, and
# hands everything else to the static assets. Its secrets — the TURN
# key — are the project's, set in the Pages dashboard, never here.
cp service/functions/worker.mjs "$STAGE/_worker.js"

# OH_UPDATE_CHECK=on is what turns on the "new build is up" pill, and it
# is passed HERE and nowhere else. Inferring it from a real-looking
# build tag would light the pill up in CI, where it floats over the
# widget tests and swallows their taps. OH_RELAYS is left empty so the
# build uses its own relay list (app/lib/net/relays.dart); the local
# rig is the only thing that sets it, to its bridges.
( cd app && "$FLUTTER" build web \
    --release \
    --no-web-resources-cdn \
    --base-href /play/ \
    --dart-define=OH_BUILD="$BUILD_TAG" \
    --dart-define=OH_RELAYS="${OH_RELAYS:-}" \
    --dart-define=OH_UPDATE_CHECK=on )

mkdir -p "$STAGE/play"
cp -r app/build/web/. "$STAGE/play"/

# The pill polls this file and compares it with the tag compiled in.
printf '{"build": "%s", "date": "%s"}\n' "$BUILD_TAG" "$BUILD_DATE" \
  > "$STAGE/play/build-info.json"

# The deal benchmark rides along when its wasm has been built here; the
# phone is the device the number is wanted from.
SHUFFLE_WASM=measurements/shuffle/target/wasm32-unknown-unknown/release/shuffle_bench.wasm
if [ -f "$SHUFFLE_WASM" ]; then
  mkdir -p "$STAGE/measure/shuffle"
  cp "$SHUFFLE_WASM" "$STAGE/measure/shuffle/"
  cp measurements/shuffle/bench.html "$STAGE/measure/shuffle/index.html"
  echo "==> including /measure/shuffle/"
fi

echo "==> publishing to $PROJECT ($LABEL)"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$CLOUDFLARE_TOKEN}" \
CLOUDFLARE_ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID" \
  npx --yes "wrangler@$WRANGLER_VERSION" pages deploy "$STAGE" \
    --project-name "$PROJECT" \
    --branch "$LABEL" \
    --commit-hash "$SHA" \
    --commit-dirty=true

echo
echo "site  https://$LABEL.$PROJECT.pages.dev/"
echo "app   https://$LABEL.$PROJECT.pages.dev/play"
if [ -f "$SHUFFLE_WASM" ]; then
  echo "bench https://$LABEL.$PROJECT.pages.dev/measure/shuffle/"
fi
