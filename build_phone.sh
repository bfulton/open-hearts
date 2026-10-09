#!/usr/bin/env bash
# A store build of the app: ./build_phone.sh ios | android
#
# The deal's native libraries first (crypto/build_ios.sh, or
# crypto/build_android.sh): every live table is sealed, and a phone
# without them plays alone. Then the release, compiled with what
# config/openhearts.json names (app/tool/defines.mjs): the service key it
# takes a licence from, the sign-in identifiers, and the store products.
# A release built any other way is refused, by Xcode (app/ios/
# release_check.sh) and by Gradle (app/android/app/build.gradle.kts).
#
# iOS on a Mac with Xcode, and signs with the team Xcode is set up for;
# Android with the NDK and app/android/key.properties. Anything after the
# platform goes to flutter build as it is.
set -euo pipefail
cd "$(dirname "$0")"
platform=${1:-}
shift || true
FLUTTER=${FLUTTER:-flutter}

mkdir -p app/build
node app/tool/defines.mjs app/build/defines.json
case "$platform" in
  ios)
    crypto/build_ios.sh
    (cd app && "$FLUTTER" build ipa --release --dart-define-from-file=build/defines.json "$@")
    ;;
  android)
    crypto/build_android.sh
    (cd app && "$FLUTTER" build appbundle --release --dart-define-from-file=build/defines.json "$@")
    ;;
  *)
    echo "usage: ./build_phone.sh ios|android [flutter build options]" >&2
    exit 2
    ;;
esac
