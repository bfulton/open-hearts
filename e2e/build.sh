#!/usr/bin/env bash
# The app as the browser suites drive it.
#
# Same build as the site's, with two differences. It is served at the
# root rather than /play/, and it names the rig's own service: the
# handlers the suites run in-process (drive.mjs, localService) sign
# licences with BIP-340's published pair, and a build only takes a
# licence from the service it was built to expect. The published pair
# is the point — this key licenses a rig on one machine and nothing
# else, and the real one's secret lives in the project's secrets.
set -euo pipefail
cd "$(dirname "$0")/../app"
"${FLUTTER:-flutter}" build web \
  -o build/e2e \
  --base-href / \
  --no-web-resources-cdn \
  --dart-define=OH_SERVICE_KEY=dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659 \
  "$@"
worker/build.sh build/e2e
