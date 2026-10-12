# Write a test that stays fast

Use this guide when you write a test, so that it costs no more time than the point it checks.

## Before you begin

- Know which suite the test belongs to: a package's Dart tests, the app's Flutter tests, or a browser suite in `e2e/`. For the suites, see [check.sh suites, tiers and CI jobs](../reference/test-suites.md).

## Write the test

1. Wait on a condition, never for a length of time:

   - In the simulator (`packages/table`), run the clock until the condition holds: `clock.runUntil(() => …, limitMs: …)` on `VirtualClock` (`packages/table/lib/src/sim/virtual_clock.dart`).
   - On a stream, take its `first` matching event with a `timeout`.
   - In a browser suite, use `waitFor` (`e2e/drive.mjs`).

1. Put the test's clocks on a fake clock: the simulator's `VirtualClock` in `packages/table`, or `fake_async` in the app. A test that waits out a real timer tests the machine it runs on.
1. At a sealed table, take the deal's cryptography from `rememberedCrypto()` (`package:deal/memo.dart`). Each call is answered by the library once, and from memory after, on disk for the next file and the next run. In a test on the wall clock, such as `service/test`, use `rememberedCrypto(kept: false)`, which remembers in memory only.
1. Play a game only as long as the point needs. A browser flow that has to see a game's end opens the app with `?target=1`, a game of one hand.
1. If the test has to be long, tag it `slow`, so the fast tier (`dart test -x slow`, `./check.sh quick`) leaves it to the full run. Tag one test with `tags: 'slow'`. A file's tests run one after another, so put a long test in a file of its own if it would hold a whole file up, and tag the whole file at its top:

   ```dart
   @Tags(['slow'])
   library;
   ```

## Check it worked

1. Check that the test fails when the thing it holds is broken. Break that thing on purpose, run the test, and see it fail.
1. Run the fast tiers of what you changed. The table at the end gives each suite's verdict and time, and each suite's whole output is in `build/check/<suite>.log`:

   ```bash
   ./check.sh quick
   ```

## Learn more

- [How Open Hearts is tested](../explanation/testing.md#what-keeps-it-fast): what keeps the suites fast, and why.
