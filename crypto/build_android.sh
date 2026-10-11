#!/usr/bin/env bash
# Builds the deal and the Schnorr cdylibs for Android's three ABIs and
# puts them where Gradle packs them into the app (jniLibs), where the
# Dart side opens them by name (packages/deal, deal_binding.dart;
# packages/table, schnorr_native_vm.dart). Every live table is sealed,
# so an Android build without libdeal.so plays alone: run this before
# `flutter build appbundle`, which refuses to build a release without
# them (app/android/app/build.gradle.kts).
#
# Needs the NDK Flutter builds with (ANDROID_NDK_HOME, or the newest
# under the SDK's ndk/) and the Rust targets:
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
set -euo pipefail
cd "$(dirname "$0")"

# The API level the app's minSdk is (Flutter's default, 24): the
# linker's sysroot for it is what the library may call.
API=24
# The NDK's prebuilt toolchain is named for the host; on Apple Silicon
# too it is darwin-x86_64 (it ships as a universal build).
case "$(uname -s)" in
  Linux) HOST=linux-x86_64 ;;
  Darwin) HOST=darwin-x86_64 ;;
  *) echo "build_android: no NDK toolchain for $(uname -s)" >&2; exit 1 ;;
esac
NDK="${ANDROID_NDK_HOME:-}"
if [[ -z "$NDK" ]]; then
  # The SDK where Android Studio and the command-line tools put it.
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [[ -n "$sdk" && -d "$sdk/ndk" ]] || continue
    # The newest revision (27.0.12077973 and the like), compared field
    # by field as numbers: POSIX sort, since macOS's has no -V.
    rev=$(cd "$sdk/ndk" && ls | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
    [[ -n "$rev" ]] && { NDK="$sdk/ndk/$rev"; break; }
  done
fi
[[ -n "$NDK" ]] || { echo "build_android: no NDK found: set ANDROID_NDK_HOME, or ANDROID_HOME to an SDK with ndk/ in it" >&2; exit 1; }
BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
[[ -x "$BIN/clang" ]] || { echo "build_android: no clang at $BIN (is $NDK an NDK?)" >&2; exit 1; }

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
    (cd "$crate" && cargo build --release --locked --target "$target")
    "$BIN/llvm-strip" --strip-unneeded -o "$OUT/$abi/lib$crate.so" "$crate/target/$target/release/lib$crate.so"
  done
done
ls -la "$OUT"/*/
