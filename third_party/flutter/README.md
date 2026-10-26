# Flutter's fix for a simulator's log stream

`simulator_log_stream.patch` is Flutter's fix for
[flutter/flutter#181771](https://github.com/flutter/flutter/issues/181771),
from [flutter/flutter#193142](https://github.com/flutter/flutter/pull/193142),
merged to Flutter's master branch as
`c3ed85ef987759ee54a6bce275490cde2a238dc1`, fitted to Flutter 3.47.2, the
version CI pins. No release carries it yet; 3.47.8 does not. It is licensed
under Flutter's BSD 3-Clause licence, in `LICENSE`.

## What it fixes

On an iOS simulator, the Flutter tool reads the address of the app's Dart
VM service from the simulator's log, through a `log stream` it starts as it
launches the app. In 3.47.2 nothing waits for that stream to be ready, so
when it starts late it misses the one line the app gives the address in,
and the tool then waits for the address with no end. The `ios` workflow's
simulator step hung that way three times on 2026-10-24 and 2026-10-25, each
time at "Waiting for VM Service port to be available...", until its
25-minute limit.

With the fix, the tool launches the app only once the stream has printed
its first line, or has exited. After 30 seconds without either, it says so
and goes on waiting.

## How it is used

`.github/workflows/ios.yml` applies it to the Flutter it sets up, and has
the `flutter` command build its tool again from the patched source, as it
does after any change to that source. Nothing else uses it. It changes
only how the tool launches an app on a simulator, so none of it is in any
app the tool builds.

## What was fitted

The change is Flutter's, line for line, with its tests. Two things differ,
because 3.47.2 is older than the branch the fix was made on: one line of
context above the first change, and the tests' simulator, built without
the `cpuArch` argument that 3.47.2's simulator does not take.

To check it, from this repository's root, with `FLUTTER` the path of a
checkout of Flutter 3.47.2:

```bash
git -C "$FLUTTER" apply "$PWD/third_party/flutter/simulator_log_stream.patch"
cd "$FLUTTER/packages/flutter_tools"
../../bin/cache/dart-sdk/bin/dart pub get
../../bin/cache/dart-sdk/bin/dart test test/general.shard/ios/simulators_test.dart
```

All 53 tests pass. With only the patch's tests applied, the two that wait
for the log stream fail: the app is launched before the stream has printed
anything.

## When to remove it

Once CI pins a Flutter that carries the fix, delete this folder and the
step in `.github/workflows/ios.yml` that applies it. A Flutter carries it
when, in a checkout of it, `$FLUTTER/packages/flutter_tools/lib/src/ios/simulators.dart`
says "The iOS simulator log stream did not start". The step fails if the
patch no longer applies, or the tool built again does not have it.
