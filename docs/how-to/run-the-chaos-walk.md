# Reproduce a table fault with the chaos walk and the explorer

Use this guide to find a seed or a single message that breaks a simulated table, and to replay it with every trace kept.

The chaos walk (`packages/table/tool/chaos.dart`) throws random faults at simulated tables, one seed each, and checks every side against the table's invariants. The explorer (`packages/table/tool/explore.dart`) replays a short sealed game once per message, peer and change, to find faults of ordering that random walks miss. Both are deterministic, so a seed or a run that broke once breaks again. For every flag, see [Command-line tools](../reference/tools.md).

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

1. To walk the same way as a scenario you are chasing, add its flags. For example, more strangers than a jury, each letting go of the table once it has served:

   ```bash
   dart run tool/chaos.dart --seeds 100 --sealed 14 --jurors 9 --sweep
   ```

   `--structure` also reads every side against the state machines as it walks, and reports waits that are stuck and sides that are apart. `--twins` takes accounts up on a second device as it walks.

1. After a fix, walk only the sealed seeds that broke, without the unsealed ones:

   ```bash
   dart run tool/chaos.dart --seeds 0 --sealed-only 3,7
   ```

## Replay one seed with every trace

1. Walk the seed that broke, with every client's log printed. For a seed from `--sealed` or `--sealed-only`:

   ```bash
   dart run tool/walk.dart --seed 7
   ```

   For a seed from `--seeds`, which is dealt from the seed, add `--seeded`:

   ```bash
   dart run tool/walk.dart --seed 7 --seeded
   ```

   `walk.dart` walks with the default jurors only. It takes no `--jurors`, `--sweep` or `--twins`.

1. Read the end of the output. It names the faults, what each survivor and juror holds, and whether each survivor's record verifies.

## Find a fault of ordering with the explorer

1. Run a scenario: `deal`, `two`, `leave`, `summons` or `topup`. Add `--first` to stop at the first run that breaks:

   ```bash
   dart run tool/explore.dart --scenario leave --first
   ```

   Each broken run is printed with its number, the event and peer it changed, and whether the first copy was lost or every copy was held late.

1. Replay one run with every trace, by what it changed. `--match` takes text from the broken run's line, and `--changes` names the one change, `lose` or `late`. Give the same `--fault-at` and `--hold` as the run that found it, if you gave any:

   ```bash
   dart run tool/explore.dart --scenario leave --match 'witness aeaa→6eab first said at 308ms' --changes lose
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
