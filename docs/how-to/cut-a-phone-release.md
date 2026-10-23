# Build a phone release for the App Store or Google Play

Use this guide to build a signed store release of the app for iOS or Android.

`./oh phone` builds, through `build_phone.sh`, the deal's native libraries first, then the release, compiled with what `config/openhearts.json` names (`app/tool/defines.mjs`): the service key the app takes a licence from, the app's origin, the sign-in identifiers and the store products.

## Before you begin

- Install Node, Flutter and Rust. CI pins both versions in `.github/workflows/ci.yml`. Run `flutter pub get` in `app/` once.
- Check that `config/openhearts.json` has `serviceKey` and `appOrigin`. `app/tool/defines.mjs` refuses to write the build's defines without them. For the fields, see [`config/openhearts.json`](../reference/configuration.md#configopenheartsjson).
- Set the release's version in `app/pubspec.yaml` (`version:`, the name before the `+` and the build number after it). Each store upload needs a higher build number than the last.
- For iOS: a Mac with Xcode, set up with the team that signs the app.
- For Android: the Android SDK with the NDK that Flutter builds with. `crypto/build_android.sh` finds it through `ANDROID_NDK_HOME`, or under `ndk/` in `ANDROID_HOME`, `ANDROID_SDK_ROOT` or the SDK's usual place.
- For Android: the release signing key, and `app/android/key.properties` naming it with `storeFile`, `storePassword`, `keyAlias` and `keyPassword` (read in `app/android/app/build.gradle.kts`). The file is ignored by git: never commit it.

## Build for iOS

1. Add the Rust targets that `crypto/build_ios.sh` builds for:

   ```bash
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
   ```

1. From the repository root, build the release:

   ```bash
   ./oh phone ios
   ```

   This builds the deal and Schnorr libraries as XCFrameworks into `app/ios/Frameworks`, which the Runner target embeds and signs, and then runs `flutter build ipa`. Anything after `ios` is passed to `flutter build` as it is.

1. Upload the `.ipa` from `app/build/ios/ipa/` to App Store Connect, with Xcode's Organizer or Transporter.

## Build for Android

1. Add the Rust targets that `crypto/build_android.sh` builds for:

   ```bash
   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
   ```

1. From the repository root, build the release:

   ```bash
   ./oh phone android
   ```

   This builds the deal and Schnorr libraries for three ABIs into `app/android/app/src/main/jniLibs/`, and then runs `flutter build appbundle`. Anything after `android` is passed to `flutter build` as it is.

1. Upload `app/build/app/outputs/bundle/release/app-release.aab` in the Google Play Console.

## Check it worked

1. The build finished. A release is refused when it lacks the service key (by `app/ios/release_check.sh` in Xcode, and by Gradle), when the native libraries are missing (Xcode cannot find the XCFrameworks, or Gradle finds no `libdeal.so` for an ABI), or when `app/android/key.properties` is missing. `crypto/build_android.sh` refuses a 64-bit library that isn't aligned to 16 KB, which Google Play turns away.
1. Check that the release was compiled with the key in the config:

   ```bash
   grep OH_SERVICE_KEY app/build/defines.json
   grep serviceKey config/openhearts.json
   ```

1. Check that the native libraries are in the package. For Android, expect six lines, `libdeal.so` and `libschnorr.so` for each of three ABIs:

   ```bash
   unzip -l app/build/app/outputs/bundle/release/app-release.aab | grep -E 'lib(deal|schnorr)\.so'
   ```

   For iOS, expect `deal.framework` and `schnorr.framework` under `Frameworks`:

   ```bash
   unzip -l app/build/ios/ipa/*.ipa | grep -E '(deal|schnorr)\.framework/(deal|schnorr)$'
   ```

1. For iOS, check that the `ios` workflow (`.github/workflows/ios.yml`) passed for your commit. It loads the libraries on a simulator as the app loads them (`app/integration_test/native_libs_test.dart`), and checks that a release without the key is refused.

A debug build on Android needs neither the libraries nor the signing key. On iOS, Xcode builds nothing without the XCFrameworks, so run `crypto/build_ios.sh` before a debug build there too.

## Learn more

- [The fair deal](../explanation/fair-deal.md#cost-and-keeping-it-off-the-page): why every live table needs the deal's native library.
- [The service](../explanation/service.md#licence): why a build without the service key has live play shut.
- [Mint or rotate the service key](rotate-the-service-key.md): a new key needs a new phone release.
