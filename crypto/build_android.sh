#!/usr/bin/env bash
# Builds the deal and the Schnorr cdylibs for Android's three ABIs and
# puts them where Gradle packs them into the app (jniLibs), where the
# Dart side opens them by name (packages/deal, deal_binding.dart;
# packages/table, schnorr_native_vm.dart). Every live table is sealed,
# so an Android build without libdeal.so plays alone: run this before
# `flutter build appbundle`, which refuses to build a release without
# them (app/android/app/build.gradle.kts).
#
# Needs the NDK Flutter builds with (ANDROID_NDK_HOME, or the version
# under ANDROID_HOME/ndk) and the Rust targets:
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
set -euo pipefail
cd "$(dirname "$0")"

# The API level the app's minSdk is (Flutter's default, 24): the
# linker's sysroot for it is what the library may call.
API=24
NDK="${ANDROID_NDK_HOME:-}"
if [[ -z "$NDK" ]]; then
  NDK=$(ls -d "${ANDROID_HOME:-$HOME/android-sdk}"/ndk/* 2>/dev/null | sort -V | tail -1)
fi
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -x "$BIN/clang" ]] || { echo "no NDK at '$NDK' (set ANDROID_NDK_HOME)" >&2; exit 1; }

OUT=../app/android/app/src/main/jniLibs
# Rust target, Android ABI, the NDK's clang prefix for it.
TARGETS=(
  "aarch64-linux-android arm64-v8a aarch64-linux-android"
  "armv7-linux-androideabi armeabi-v7a armv7a-linux-androideabi"
  "x86_64-linux-android x86_64 x86_64-linux-android"
)
for t in "${TARGETS[@]}"; do
  read -r target abi clang <<<"$t"
  upper=$(echo "$target" | tr 'a-z-' 'A-Z_')
  export "CARGO_TARGET_${upper}_LINKER=$BIN/${clang}${API}-clang"
  export "CC_${target//-/_}=$BIN/${clang}${API}-clang"
  export "AR_${target//-/_}=$BIN/llvm-ar"
  mkdir -p "$OUT/$abi"
  for crate in deal schnorr; do
    (cd "$crate" && cargo build --release --offline --target "$target")
    "$BIN/llvm-strip" --strip-unneeded -o "$OUT/$abi/lib$crate.so" "$crate/target/$target/release/lib$crate.so"
  done
done
ls -la "$OUT"/*/
