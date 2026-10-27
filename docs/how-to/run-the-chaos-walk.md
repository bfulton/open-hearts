# Reproduce a table fault with the chaos walk and the explorer

Use this guide to find a seed or a single message that breaks a simulated table, and to replay it with every trace kept.

The chaos walk (`packages/table/tool/chaos.dart`) throws random faults at simulated tables, one seed each, and checks every side against the table's invariants. The explorer (`packages/table/tool/explore.dart`) plays a short sealed game once per event and change, to find faults of ordering that random walks miss. Both are deterministic, so a seed or a run that broke once breaks again. For every flag, see [Command-line tools](../reference/tools.md).

## Before you begin

- Install Dart and Rust, and run `dart pub get` in `packages/table/`.
- Build the deal's library, which sealed walks and the explorer load:

  ```bash
  (cd crypto/deal && cargo build --release --locked)
  ```

- Run the commands from `packages/table/`.

## Find a broken seed

1. Walk many seeds. `--seeds` walks tables dealt from a seed, which is fast; `--sealed` adds that many seeds with the verifiable deal run for real, a minute or two each:

   ```bash
   dart run tool/chaos.dart --seeds 250 --sealed 6
   ```

   The walk prints `seed N: …` for each seed that broke an invariant, with the faults that led there, and exits with 1 if any did. It ends with a line that counts the seeds and the broken ones.

1. To walk the sealed seeds with the deal's slow calls in a worker that takes a browser's time over them, as the app does, add `--workers`. To count what the walks did (how games ended, how seats were given up, the faults thrown), add `--tally`:

   ```bash
   dart run tool/chaos.dart --seeds 0 --sealed 14 --workers --tally
   ```

1. After a fix, walk only the sealed seeds that broke, without the unsealed ones:

   ```bash
   dart run tool/chaos.dart --seeds 0 --sealed-only 3,7
   ```

## Replay one seed with every trace

1. Walk the seed that broke with `--traces`, which prints every side's trace: each person's, the house's follower and each seat it plays. For a sealed seed:

   ```bash
   dart run tool/chaos.dart --seeds 0 --sealed-only 7 --traces
   ```

   For an unsealed seed, `--seeds` walks every seed below the number given, so walk up to the one that broke: `--seeds 8 --traces` ends with seed 7.

1. Read the end of the output. It names the faults that led there and the invariant that broke: two sides that saw the table differently after an entry, a game not over as the faults allow, a seat lost by no fault of its own, something taken twice, or the house's word on the end missing or wrong.

## Find a fault of ordering with the explorer

1. List the scenarios: a name that is not one prints them all, each with what it plays.

   ```bash
   dart run tool/explore.dart --scenario help
   ```

1. Run a scenario. Add `--first` to stop at the first run that breaks:

   ```bash
   dart run tool/explore.dart --scenario leave --first
   ```

   Each broken run is printed with the event it changed, and how: `drop` (lost on the way and said again on the next socket), `late` (the sender off the network for a few seconds) or `twice` (sent twice).

1. Replay one run with every trace. `--census` lists the events the scenario sends, numbered; `--at` runs the change to one of them, and `--changes` names the change:

   ```bash
   dart run tool/explore.dart --scenario leave --census
   dart run tool/explore.dart --scenario leave --at 41 --changes late
   ```

## Check it worked

1. A replayed seed or run breaks the same way as in the walk that found it, since the simulator is deterministic.
1. After a fix, the same command exits with 0. The chaos walk ends with `every invariant held`, and the explorer with `every one held`.
1. Run the chaos walks that the table's tests run:

   ```bash
   dart test test/chaos_test.dart test/chaos_sealed_test.dart
   ```

## Learn more

- [The table's states](../explanation/table-states.md#how-it-is-checked): what the walk holds every side to.
- [How Open Hearts is tested](../explanation/testing.md): where the chaos walk and the explorer sit among the tests.
