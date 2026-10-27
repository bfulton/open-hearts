#!/usr/bin/env bash
# The app as the browser suites drive it.
#
# Same build as the site's, base / and all, served the way the site
# serves it (drive.mjs: at the root of play.openhearts.localhost, and at
# /play/ on 127.0.0.1, the rig's preview), with one difference: it
# names the rig's own service and its own house. The
# handlers the suites run in-process (drive.mjs, localService) sign
# licences with BIP-340's second published pair, and a build only takes a
# licence from the service it was built to expect; the rig's house is
# BIP-340's third, every table this build seats names it, and the
# rig's relay referees tables for it alone. The published pairs are the
# point — these keys run a rig on one machine and nothing else, and the
# real ones' secrets live in the project's secrets.
#
# Made once for every suite, and not again while what it is made from
# is unchanged: the sources it compiles, the packages it takes by path,
# the page around it, this script and the flags it is given, and the
# Flutter that compiles it. --force makes it anyway. Without the wasm
# dry run, which only warns, and which the CI's own web build still
# makes (.github/workflows/ci.yml).
#
# And the house the suites start, compiled ahead of time once for
# whatever service/ is at (drive.mjs, serviceProgram), so that suites
# started together do not each compile it.
set -euo pipefail
cd "$(dirname "$0")/../app"
( cd .. && node --input-type=module -e "const d = await import('./e2e/drive.mjs'); await d.serviceProgram('house');" ) &
programs=$!
force=0
args=()
for a in "$@"; do
  if [ "$a" = --force ]; then force=1; else args+=("$a"); fi
done
flutter="${FLUTTER:-flutter}"
sdk="$(dirname "$(command -v "$flutter")")/cache"
stamp=build/e2e/.made-from
made_from() {
  {
    cat "$sdk/flutter.version.json" "$sdk/engine.stamp" 2>/dev/null
    echo "${args[*]:-}"
    find lib web worker pubspec.yaml pubspec.lock l10n.yaml ../packages/*/lib ../packages/*/pubspec.yaml \
      ../e2e/build.sh -type f 2>/dev/null | LC_ALL=C sort | xargs sha1sum
  } | sha1sum | cut -c1-40
}
want=$(made_from)
if [ $force = 0 ] && [ -f build/e2e/main.dart.js ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
  echo "build/e2e is up to date (made from ${want:0:12}); --force to make it again"
  wait $programs
  exit 0
fi
rm -f "$stamp"
"$flutter" build web \
  -o build/e2e \
  --base-href / \
  --no-web-resources-cdn \
  --no-wasm-dry-run \
  --dart-define=OH_SERVICE_KEY=dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659 \
  --dart-define=OH_HOUSE_KEY=dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8 \
  ${args[@]+"${args[@]}"}
worker/build.sh build/e2e
echo "$want" > "$stamp"
wait $programs
