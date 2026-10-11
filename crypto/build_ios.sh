#!/usr/bin/env bash
# Builds the deal and the Schnorr cdylibs for iOS, each as a framework
# in an XCFramework (a device slice, and a simulator slice for Apple
# silicon and Intel Macs), and puts them where the Runner target embeds
# and signs them (app/ios/Frameworks, Runner.xcodeproj). The Dart side
# opens them by name (packages/deal, deal_binding.dart; packages/table,
# schnorr_native_vm.dart). Every live table is sealed, so the app is not
# built without them: Xcode refuses a project whose XCFramework is not
# there. Run this before `flutter build ipa`, or `flutter run` on iOS.
#
# On a Mac with Xcode, and the Rust targets:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
set -euo pipefail
cd "$(dirname "$0")"

# The app's IPHONEOS_DEPLOYMENT_TARGET (Runner.xcodeproj): what rustc
# links the libraries for, and what each framework says it needs.
export IPHONEOS_DEPLOYMENT_TARGET=15.0

OUT=../app/ios/Frameworks
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A framework of one dylib: the binary named as the framework, its
# install name where the app's Frameworks puts it, and the Info.plist
# the App Store checks an embedded framework for.
framework() {
  local crate=$1 platform=$2 dir=$3
  shift 3
  local fw="$dir/$crate.framework"
  mkdir -p "$fw"
  lipo -create "$@" -output "$fw/$crate"
  install_name_tool -id "@rpath/$crate.framework/$crate" "$fw/$crate"
  # Local symbols only: what the app looks up are the exported ones.
  strip -x "$fw/$crate"
  cat >"$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$crate</string>
	<key>CFBundleIdentifier</key>
	<string>game.openhearts.$crate</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$crate</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$platform</string>
	</array>
	<key>MinimumOSVersion</key>
	<string>$IPHONEOS_DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
}

mkdir -p "$OUT"
for crate in deal schnorr; do
  for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    (cd "$crate" && cargo build --release --locked --target "$target")
  done
  lib() { echo "$crate/target/$1/release/lib$crate.dylib"; }
  framework "$crate" iPhoneOS "$WORK/device" "$(lib aarch64-apple-ios)"
  framework "$crate" iPhoneSimulator "$WORK/simulator" "$(lib aarch64-apple-ios-sim)" "$(lib x86_64-apple-ios)"
  rm -rf "$OUT/$crate.xcframework"
  xcodebuild -create-xcframework \
    -framework "$WORK/device/$crate.framework" \
    -framework "$WORK/simulator/$crate.framework" \
    -output "$OUT/$crate.xcframework"
done
ls -la "$OUT"/*.xcframework/*/
