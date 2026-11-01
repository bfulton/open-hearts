#!/usr/bin/env bash
# Publish the site and the app to Cloudflare Pages.
#
# Assembles one directory and uploads it once:
#
#   /            the marketing site, in each of its languages (site/build.mjs)
#   /api/        the service's handlers (service/functions/, published
#                as the _worker.js/ directory, entry.mjs its index.js)
#   /play/       the Flutter web build, base-href / : served at the root
#                of play.openhearts.game, and at /play/ on a preview
#                (the worker routes by host, docs/explanation/service.md)
#
# Publishing is for looking at, not for keeping: every upload is a
# deployment Cloudflare keeps until it is deleted. ./oh deploy site
# deletes the old ones before each production deploy, and
# ./oh deploy prune does it on its own (ops/release.mjs, sweep).
#
# Usage:  ./deploy.sh [branch-label], or better, ./oh deploy site
# (docs/reference/oh.md), which says first what stands in the way.
#
# The label names the Pages branch, and Cloudflare gives every branch a
# stable alias URL. Default is "dev" on any working branch — a short,
# bookmarkable host that does not change as branches come and go — and
# "main" (which is production, so the custom domains: the site at
# openhearts.game, the app at play.openhearts.game) on main.
#
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID in the environment,
# checked before anything is built.
set -euo pipefail
cd "$(dirname "$0")"
for need in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID; do
  [ -n "${!need:-}" ] || { echo "deploy: $need is not set" >&2; exit 1; }
done

PROJECT=$(node --input-type=module -e "import { pages } from './infra/cloudflare.mjs'; process.stdout.write(pages.project)")
FLUTTER=${FLUTTER:-flutter}
STAGE=build/publish

branch_of_git() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo dev
}

LABEL=${1:-}
case "$LABEL" in
  # Not a branch: the sweep this took once (--prune) is ./oh deploy prune.
  -*) echo "deploy: $LABEL is not a label; old deployments are swept by ./oh deploy prune" >&2; exit 2 ;;
esac
if [ -z "$LABEL" ]; then
  LABEL=$([ "$(branch_of_git)" = main ] && echo main || echo dev)
fi

# Production only from main as it was reviewed, and only when nothing
# else stands in the way (ops/gate.mjs), whether or not oh started this.
if [ "$LABEL" = main ]; then
  node ops/gate.mjs site || { echo "deploy: not deployed to production" >&2; exit 1; }
fi

# What the app is built with comes from config/openhearts.json, committed,
# and from nothing in the environment (app/tool/defines.mjs, as for a
# phone build). Production's is refused without the service's key, since
# a build that trusts no licence has live play shut for everyone, and
# without the house's, since a build without it seats nobody live. A
# preview is a deployment of its own (docs/how-to/deploy.md): its app
# takes licences signed with the key previews have (preview.serviceKey),
# never production's, and plays on the preview relay, never
# production's. Its worker takes the same key from the same file, since
# its environment says it is a preview (OH_DEPLOYMENT, infra/cloudflare.mjs).
mkdir -p app/build
node app/tool/defines.mjs app/build/defines.json "$([ "$LABEL" = main ] && echo production || echo preview)"

# The build's identity, as defines.mjs wrote it for the build, so the
# pill's build-info.json below names exactly what was compiled in. "+"
# marks a dirty tree: the deploy holds work newer than the sha it claims.
define_of() { node -p "require('./app/build/defines.json').$1"; }
BUILD_TAG=$(define_of OH_BUILD_TAG)
BUILD_DATE=$(define_of OH_BUILD_DATE)
SHA=${BUILD_TAG%+}
DIRTY=$([ "$SHA" != "$BUILD_TAG" ] && echo true || echo false)

echo "==> building $BUILD_TAG -> $LABEL"

rm -rf "$STAGE"
mkdir -p "$STAGE"
node site/build.mjs "$STAGE"
# The service's handlers (docs/explanation/service.md) run as the Pages worker:
# _worker.js/ at the root of what is published answers /api/…, and
# hands everything else to the static assets. Its secrets are the Pages
# project's (infra/cloudflare.mjs), set with ./oh, never here.
# A directory rather than one file: the entry imports the signature
# wasm as a module, which Cloudflare compiles at upload — it refuses to
# compile wasm from bytes while running (service/functions/entry.mjs).
mkdir -p "$STAGE/_worker.js"
cp service/functions/entry.mjs "$STAGE/_worker.js/index.js"
# The committed configuration, as a module the entry imports; and the
# ledger of the terms and the privacy policy this site is built with,
# which the service tells subscribers of (service/functions/notices.mjs).
node -e "process.stdout.write('export default ' + JSON.stringify(require('./config/openhearts.json')) + ';\n')" \
  > "$STAGE/_worker.js/openhearts.config.mjs"
node -e "process.stdout.write('export default ' + JSON.stringify(require('./site/ledger.json')) + ';\n')" \
  > "$STAGE/_worker.js/ledger.config.mjs"
# Every module the handlers import, not a list of them kept by hand:
# one left off is a worker Cloudflare refuses at upload. Not the tests,
# nor their fixtures.
for f in service/functions/*.mjs; do
  case "$f" in *.test.mjs | *.fixtures.mjs | */entry.mjs) continue ;; esac
  cp "$f" "$STAGE/_worker.js/"
done
cp app/web/schnorr.wasm "$STAGE/_worker.js/schnorr.wasm"
# And loaded here before anything is uploaded: a module that imports
# one that is not there fails now, not at Cloudflare's end.
node --input-type=module -e "await import('file://$(cd "$STAGE" && pwd)/_worker.js/worker.mjs')" ||
  { echo "deploy: the staged worker does not load" >&2; exit 1; }

# The defines, app/build/defines.json above:
#
# OH_RELAYS is not set for production, so the build uses its own relay
# list (app/lib/net/relays.dart); a preview's names the preview relay,
# as the local rig's names its bridges.
# OH_BUILD_TAG and OH_BUILD_DATE are the build's identity, compiled in
# since a build cannot fetch its own (app/lib/build_info.dart): the About
# page shows them, and the remote config's update notice compares the
# date. OH_UPDATE_CHECK turns on the "new build is up" pill.
#
# OH_SERVICE_KEY (serviceKey in the config, preview.serviceKey for a
# preview) names the service this build will take a licence from, and no
# other (docs/explanation/service.md, app/lib/net/licence.dart): the
# public half of a pair whose secret is set on the Pages project's
# environment as OH_SERVICE_SECRET and lives nowhere else. A build
# published without it has live play shut, which is the safe way round:
# the alternative is a build that would take a licence from whoever
# answered first.
#
# OH_HOUSE_KEY (houseKey, preview.houseKey for a preview) is the house
# every live table this build seats names (docs/explanation/live-play.md,
# app/lib/net/licence.dart): the house that deals its bot seats, holds
# half of each person's escrow and says how the game came out, whose
# secret is the relay worker's OH_HOUSE_SECRET. A build without it seats
# nobody live.
#
# OH_GOOGLE_CLIENT_ID and OH_APPLE_SERVICE_ID (google.webClientId and
# apple.servicesId in the config) are the sign-in providers' identifiers
# (docs/explanation/service.md, app/lib/net/provider_tokens.dart).
# Neither is a secret. A build without one offers no sign-in with that
# provider. The rest, the app's origin and the store products, are read
# only by a phone build.
#
# The base is / : production serves the app at the root of
# play.openhearts.game. A preview, which has no such host, serves the
# same files at /play/, its worker moving the page's base there
# (service/functions/app_host.mjs, serveStatic).
# --source-maps publishes main.dart.js.map beside it, so a stack the
# browser agent sends (app/lib/net/report_error.dart) can be read back to
# the Dart that threw. The source is public already.
( cd app && "$FLUTTER" build web \
    --release \
    --source-maps \
    --no-web-resources-cdn \
    --base-href / \
    --dart-define-from-file=build/defines.json )
FLUTTER="$FLUTTER" app/worker/build.sh app/build/web

mkdir -p "$STAGE/play"
cp -r app/build/web/. "$STAGE/play"/

# The pill polls this file and compares it with the tag compiled in.
printf '{"build": "%s", "date": "%s"}\n' "$BUILD_TAG" "$BUILD_DATE" \
  > "$STAGE/play/build-info.json"

echo "==> publishing to $PROJECT ($LABEL)"
ops/wrangler/wrangler pages deploy "$STAGE" \
    --project-name "$PROJECT" \
    --branch "$LABEL" \
    --commit-hash "$SHA" \
    --commit-dirty="$DIRTY"

echo
echo "site  https://$LABEL.$PROJECT.pages.dev/"
echo "app   https://$LABEL.$PROJECT.pages.dev/play/"
if [ "$LABEL" = main ]; then
  echo "      https://play.openhearts.game/ (production, and its /api/)"
else
  echo "live  on the preview relay, with the people you invite (./oh preview invite)"
fi
