# Get started: from a fresh clone to tests and the app

This tutorial takes you from a fresh clone of Open Hearts to passing tests and the app running in Chrome on your computer.

You install the tools, run the engine's tests, build the deal library, check a change as you would before a pull request, and play a solo game in the app. You need a macOS or Linux computer and an internet connection.

## Step 1: Install the tools

1. Install [Git](https://git-scm.com/downloads) and [Google Chrome](https://www.google.com/chrome/).
1. Install [Flutter](https://docs.flutter.dev/get-started/install) from the stable channel, with web as the target platform. Flutter includes Dart.
1. Install [Node.js](https://nodejs.org/en/download) 22, the version CI uses (`node-version` in `.github/workflows/ci.yml`).
1. Install [rustup](https://rustup.rs), the Rust installer. You choose the Rust version in step 4.
1. Check Flutter:

   ```bash
   flutter --version
   ```

   The output names the Flutter and Dart versions. This tutorial was tested with Flutter 3.47.2 and Dart 3.13.2. CI pins the Flutter version as `flutter-version` in `.github/workflows/ci.yml`.

1. Check that Flutter can find Chrome:

   ```bash
   flutter devices
   ```

   The list includes a line that starts with `Chrome (web)`.

1. Check Node.js and rustup:

   ```bash
   node --version
   rustup --version
   ```

   `node --version` prints a version that starts with `v22`, and `rustup --version` prints `rustup` followed by its version.

## Step 2: Clone the repository

```bash
git clone https://github.com/bfulton/open-hearts.git
cd open-hearts
```

Run the rest of this tutorial from this `open-hearts` directory, the root of your clone.

## Step 3: Run the engine's tests

The engine is the rules of Hearts and the bots in pure Dart, so its tests need nothing but Dart ([the engine](../../packages/engine/README.md)).

```bash
cd packages/engine
dart pub get
dart test
cd ../..
```

`dart pub get` downloads the engine's dependencies. `dart test` shows its progress as it runs and ends with `All tests passed!`. The last command takes you back to the root of your clone.

## Step 4: Use the Rust version that CI pins

The browser's copy of the deal is WebAssembly committed to the repository, and building it with the Rust version that CI pins reproduces the committed bytes exactly ([why the wasm is committed](../explanation/dev-loop.md#why-the-wasm-is-committed)).

1. Print the Rust version that CI pins:

   ```bash
   grep -m1 'toolchain:' .github/workflows/ci.yml
   ```

   It prints `toolchain: 1.97.0`, the version this tutorial was tested with. If it prints a different version, use that version in the next two commands.

1. Install that version with the WebAssembly target:

   ```bash
   rustup toolchain install 1.97.0 --target wasm32-unknown-unknown
   ```

1. Use that version in this directory only:

   ```bash
   rustup override set 1.97.0
   ```

1. Check the version:

   ```bash
   rustc --version
   ```

   It prints `rustc 1.97.0`, followed by a commit and a date.

## Step 5: Build the deal library

The deal library is the Rust cryptography that deals each live hand so that every player can check the deal was fair ([the fair deal](../explanation/fair-deal.md)).

1. Build it:

   ```bash
   crypto/deal/build.sh
   ```

   The first build downloads and compiles the library's Rust dependencies, so it takes longer than later builds. The script ends by listing what it built: `libdeal.so` (`libdeal.dylib` on macOS), the library the Dart VM loads, and `deal.wasm`, the browser's copy.

1. Check that the WebAssembly you built is the committed one:

   ```bash
   git status
   ```

   It prints `nothing to commit, working tree clean`.

1. Run the deal's tests, which load the library you built:

   ```bash
   cd packages/deal
   dart pub get
   dart test
   cd ../..
   ```

   The last line ends with `All tests passed!`.

## Step 6: Check a change

`./check.sh quick` runs the checks for what you changed since `origin/main`, each at its fast tier ([two tiers of checks](../explanation/dev-loop.md#two-tiers-of-checks)). [CONTRIBUTING.md](../../CONTRIBUTING.md) asks you to run it before you open a pull request.

1. Run it on your fresh clone:

   ```bash
   ./check.sh quick
   ```

   It prints `nothing changed since origin/main`, because you have not changed anything yet.

1. Make a one-line change to the engine:

   ```bash
   echo '// My first change.' >> packages/engine/lib/engine.dart
   ```

1. Run the checks again:

   ```bash
   ./check.sh quick
   ```

   It prints `changed since origin/main: 1 files; checking engine docs`, runs the engine's suite and the docs' link check side by side, and ends with a table like this one. Your times differ.

   ```text
   suite          result   time
   docs           pass       1s
   engine         pass      15s
   total          pass      15s
   ```

   Each suite's full output is in the `build/check/` directory. [What quick runs](../reference/test-suites.md#what-quick-runs) lists which suites each kind of change runs.

1. Undo the change:

   ```bash
   git restore packages/engine/lib/engine.dart
   ```

## Step 7: Run the app

1. Start the app in Chrome:

   ```bash
   cd app
   flutter run -d chrome
   ```

   Flutter downloads the app's dependencies, compiles the app and prints `Launching lib/main.dart on Chrome in debug mode...`. The first compile takes a while. When it finishes, a Chrome window opens on the Open Hearts home screen, with a **Play solo** button, and the terminal lists Flutter's key commands.

1. In Chrome, click the menu at the top left, and then click **About**. **Build** and **Published** both say `dev`, because only a deployed build has its commit compiled in ([knowing which build is running](../explanation/dev-loop.md#knowing-which-build-is-running)).
1. Click the back arrow, and then click **Play solo**. A game against three bots starts, and the app deals you 13 cards and asks you to choose three to pass.
1. When you finish playing, press `q` in the terminal to stop the app.

You now have a working clone: tested, built and running.

## Next steps

- [Open Hearts documentation](../README.md) lists every tutorial, guide, reference page and explanation.
- [Run the browser suites](../how-to/run-the-browser-suites.md) to drive the built app in a browser, as `./check.sh full` and CI do.
- [How a change reaches a phone](../explanation/dev-loop.md) explains the development loop, from a commit to a phone.
- [How Open Hearts is tested](../explanation/testing.md) explains the test tiers and why the suites are split as they are.
- [Multiplayer through a referee](../explanation/multiplayer.md) and [the fair deal](../explanation/fair-deal.md) explain how live play works.
