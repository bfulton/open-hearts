#!/usr/bin/env bash
# A Runner build phase (Runner.xcodeproj, "Release needs the service
# key"): a Release build is refused unless it was compiled with the
# service's public key (OH_SERVICE_KEY, from config/openhearts.json by
# build_phone.sh). Without it the app takes no licence and live play is
# shut, which a store's review would find before anyone else did.
# Debug builds are untouched.
set -euo pipefail
[[ "${CONFIGURATION:-}" == Release ]] || exit 0
key=""
IFS=',' read -ra defines <<<"${DART_DEFINES:-}"
for d in "${defines[@]}"; do
  v=$(printf '%s' "$d" | base64 --decode 2>/dev/null || true)
  case "$v" in OH_SERVICE_KEY=*) key=${v#OH_SERVICE_KEY=} ;; esac
done
if [[ ! "$key" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: a Release build needs the service key: build with ./build_phone.sh ios, which passes config/openhearts.json's serviceKey" >&2
  exit 1
fi
