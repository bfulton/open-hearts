#!/usr/bin/env bash
# A store build of the app: ./build_phone.sh ios | android
#
# The deal's native libraries first (crypto/build_ios.sh, or
# crypto/build_android.sh): every live table is sealed, and a phone
# without them plays alone. Then the release, compiled with what
# config/openhearts.json names (app/tool/defines.mjs): the service key it
# takes a licence from, the sign-in identifiers, and the store products;
# and the build's commit and date, which the About page shows and the
# remote config's update notice compares.
# A release built any other way is refused, by Xcode (app/ios/
# release_check.sh) and by Gradle (app/android/app/build.gradle.kts).
# A store release is production, so it is built only from main as it
# was reviewed (ops/gate.mjs), whether or not oh started this.
#
# iOS on a Mac with Xcode, and signs with the team Xcode is set up for;
# Android with the NDK and app/android/key.properties. Anything after the
# platform goes to flutter build as it is.
set -euo pipefail
cd "$(dirname "$0")"
platform=${1:-}
shift || true
FLUTTER=${FLUTTER:-flutter}

case "$platform" in
  ios | android) ;;
  *)
    echo "usage: ./build_phone.sh ios|android [flutter build options]" >&2
    exit 2
    ;;
esac
node ops/gate.mjs phone || { echo "build_phone: not built" >&2; exit 1; }

mkdir -p app/build
node app/tool/defines.mjs app/build/defines.json
if [ "$platform" = ios ]; then
  crypto/build_ios.sh
  (cd app && "$FLUTTER" build ipa --release --dart-define-from-file=build/defines.json "$@")
else
  crypto/build_android.sh
  (cd app && "$FLUTTER" build appbundle --release --dart-define-from-file=build/defines.json "$@")
fi
