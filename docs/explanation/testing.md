# How Open Hearts is tested

This page explains how the tests are arranged, what makes some of them
slow, and what keeps the whole run short. Every suite, the files a quick
run maps to it, and the CI jobs are in the
[test suites reference](../reference/test-suites.md).

## One script, two tiers

Every suite is in `./check.sh`, and CI runs the same suites in jobs side
by side (`.github/workflows/ci.yml`). One more needs a Mac, so
`./check.sh` does not run it: the `ios` workflow
(`.github/workflows/ios.yml`) builds the deal's frameworks and the app,
and checks on a simulator that the libraries load as the app loads them
and make the same bytes as the build the other suites test
(`app/integration_test/native_libs_test.dart`).

`quick` checks what a change touches. It reads the paths that differ from
the base (commits since the merge base, the index, the working tree, new
files) and runs the suites those paths are in, each at its fast tier.
For the app it runs only the tests whose imports reach a changed file
(`app/tool/affected_tests.mjs`), or all of them for a change to the
pubspec, the words or the test config. `full` runs every suite (the
Rust crates' own tests only where cargo has built them), so it also
checks what a change touches in turn, such as the service and the
app over a changed `packages/table`. CI runs the same suites, and also
builds the web app as `deploy.sh` does and checks that the committed
wasm is the bytes its sources make
([CI jobs](../reference/test-suites.md#ci-jobs)).

## Tiers

`dart test` and `flutter test` run everything a package has. The table's
long cases, such as whole sealed games played out under every departure
and the chaos walks past their first seeds, carry the tag `slow`
(`packages/table/dart_test.yaml`). The fast tier leaves them out, and a
full run includes them. Nothing is only in the slow tier that a fast run
would have caught sooner: a tag moves a test, it never drops one. The
app's fits matrix (every shape, text size and language) is its `slow`
(`app/dart_test.yaml`), which `quick` leaves to `full`.

## What makes a suite slow

- **The table's sealed games.** Not the clock: the simulator runs on its
  own (`VirtualClock`), and a table plays minutes of table time in
  milliseconds. The time is the deal's cryptography, run for real: every
  person and juror at the table checks each shuffle proof, the verifier
  checks it again, and a file's tests play the same seeds into one
  departure after another, so most calls into the library are ones it
  has answered before.
- **The service's games over real sockets**, such as two tables whose
  jurors are each other's people. These run on the wall clock on
  purpose, with real relays and real signatures.
- **The app's widget tests**: rendering, and the fits matrix above all.
  They have no real-time waits; everything is pumped on the test clock.
- **The browser suites**: real time by nature, and most of it the
  table's own beats (a bot thinking, each trick held a moment) and its
  clocks (the silence before a gone person is ruled on, the bank before
  a seat can be booted).
- **The browser drawing.** Headless Chromium draws the app in software,
  and a page with something always moving, such as the folding heart or
  the turn pill, keeps a core busy for as long as it is open.

## What keeps it fast

- **The deal's answers, remembered.** Sealed tests take the library
  through `rememberedCrypto()` (`packages/deal/lib/memo.dart`): the
  library answers each call once, and memory answers it after that. The
  answers are kept on disk beside the library that gave them, under
  `crypto/deal/target/memo/`, for the next file and the next run. A
  rebuilt library answers everything afresh, and `OH_DEAL_MEMO=off` keeps
  nothing. A proof changed by one byte is new bytes, asked anew, so a
  test of a bad proof still sees the library say no. The service's tests
  on the wall clock keep answers in memory only, so a device's own
  shuffle still costs what it costs there. CI caches the directory,
  keyed on the deal's sources.
- **Files side by side.** The table and the service run four files at a
  time by default (`concurrency` in their `dart_test.yaml`), and
  `./check.sh` runs one file per core. A file's own tests run one after
  another, so a long file is split: the sealed table's tests are three
  files, the jury over the relay two.
- **A game as long as the point needs.** The service's two tables play
  to 27, which still guarantees two hands
  (`service/test/two_tables_jury_each_other_test.dart`). A browser flow
  that has to see a game end plays one hand (`?e2e=1&target=1`).
- **The browser suites side by side.** Each suite starts its relay on a
  port of its own and names that port in every address it opens
  (`?relay=PORT`, which only a build served from this machine reads).
  The flows are shared among a few workers, each with a rig of its own,
  so no flow meets another (`e2e/pool.mjs`). A flow that needs a relay
  starts its own on its worker's port, and the relay goes when the flow
  does, so no flow inherits what another left running. The app is built
  once (`e2e/build.sh`, and not again until its sources change), and the
  relay and the jurors are compiled ahead of time once, as the backup
  jurors' container runs them.
- **The table's beats and clocks, shortened where a suite waits on
  them.** The browser suites open the app at a tenth of its tables'
  beats (`?pace=0.1`). Where a test waits on a table's clock, the rig's
  handlers serve a remote config that sets the clock to the least it may
  be, through the same `config` route the operator uses. The tests are
  the same; only the waits are shorter. The device's own waits on the
  network are the build's, which the `offline` suite times.
- **Pages that stand still.** A flow that does not look at motion opens
  its pages asking for reduced motion, which the app honours, at one
  device pixel to the point, so a page waiting on a turn costs a
  fraction of the CPU. The flows that look at motion or at pixels, such
  as a hand alone or the thumb's reach, keep both.

A shortened test is checked against its own failure: with the thing it
holds broken on purpose (no escrow piece ever released, a bad seal let
through, no second deal, the end of a game left unshown), it must still
fail.

To write a test that stays fast, see
[Write a test that stays fast](../how-to/write-a-fast-test.md).

## What each area's tests hold

### The deal

- `packages/deal`: every primitive round trips. Four sessions in one
  process deal, pass, play, lose a seat and rebuild it, and audit, and a
  verifier that saw only the messages checks the result. The share-token
  path opens a departed seat's hand and a pass sealed to it while
  `knowsSecret` stays false.
- `packages/table/test/sealed_test.dart`: whole sealed games at one, two
  and four people that verify to the end. It covers leaving mid-hand and
  during the deal, and a table of two surviving a crash through the jury.
  It also commits both faults for real, every seat disclaiming the 2♣ and
  a pass sealed to nothing, and each game still finishes and verifies.
- `service/test` runs the jury sealed over real sockets, and the browser
  suites deal every hand this way.
- `packages/engine/test/deal_seed_test.dart` and
  `packages/engine/test/solo_record_test.dart` cover the solo deal. They
  check the generator against known answers worked out in Python from
  [its description](fair-deal.md#solo-games-where-the-randomness-comes-from),
  rejection of uneven draws, uniformity over all orders of four cards,
  and a χ² over 52 × 52 positions that two broken shuffles fail. They
  also check that records of both versions replay trick for trick, on the
  VM and in Chrome.

### The table

The table protocol's job is to keep four seats playing while people
come and go. The same client code runs in-process over a simulated
network (latency, drops, partitions) on a virtual clock, replayable from
a seed, over real sockets, and in real browsers. Every scenario asserts
that:

- the game reaches its end with a bot in each departed seat, or pauses,
  says why, and ends unscored ("juror quorum lost");
- every survivor holds the same record, and the record verifies: every
  play signed and legal, every bot play recomputable, and every proof,
  token and audit at a sealed table;
- nobody is removed without a strict majority of the last agreed
  participants, so a partition never forks;
- nothing hangs.

The harnesses:

- The departure matrix (`packages/table/test/matrix_test.dart`) runs
  leaves, boots and silences on the simulated network on every commit.
  It varies how many people start, who goes (players, jurors, the whole
  jury), how (a signed leave, a silent drop, a boot, a partition) and
  when (on or off turn, mid-trick, during the pass or deal, at a hand
  boundary).
- The chaos walk (`packages/table_sim/lib/src/chaos_walk.dart`, run by
  `chaos_test.dart`, `chaos_sealed_test.dart` and
  `packages/table/tool/chaos.dart`) throws random
  faults at simulated tables: devices dropping, relays failing, loss,
  jurors leaving once they have served, and accounts taken up on new
  devices. It fails a run on any broken invariant, on two devices of one
  account at the table at once, on a jury drawn from an account seated
  at it, on a table left stopped where nobody up could move it, on sides
  still apart on the escrow once the faults have stopped and the network
  has healed (sides that ended the game for themselves aside), and on
  any two records, the people's and every following juror's, naming
  different exits for one seat.
- The explorer (`packages/table/tool/explore.dart`) replays a short
  sealed game once per event, peer and change, with the first copy lost
  or every copy late and nothing else different (`SimNetwork.steer`),
  and holds each run to what the table owes. It finds the ordering
  faults that random walks miss.
- The structure checker (`packages/table_sim/lib/src/structure.dart`)
  reads every side against the
  [table's machines](table-states.md#the-machines) during a run and at
  its end ([how it is checked](table-states.md#how-it-is-checked)).
- `service/test` runs the jury, and a backup juror summoned to a table,
  over a real relay.
- The browser suites (`e2e/`) match strangers with bots and play a
  friends' room through its departures, four headless browsers over
  WebRTC.

To run the walk and the explorer, see
[Reproduce a table fault with the chaos walk](../how-to/run-the-chaos-walk.md).
Their flags are in the [tools reference](../reference/tools.md).

### The app in a browser

The browser suites (`e2e/`) open the built app with `?e2e=1`, which
builds the accessibility tree from the start, and drive it through that
tree. The rig (`serveApp` in `e2e/drive.mjs`) serves the site and the
app as the Pages project does: the site built in every language, the
app, and the site's own worker in front of both, routing by host
([where the app is](service.md#where-the-app-is)). Production's hosts
have stand-ins that Chromium takes to be this machine and to be one
site, as production's two are: `play.openhearts.localhost` is the app
at its root, `openhearts.localhost` the site, and `127.0.0.1` a preview,
with the app at `/play/`. So the suites go through the same routing,
the same carry-over and the same handlers as production.

### The service

- **Every relay.** The `service/` suite runs against the local Dart
  relay, against the relay the Cloudflare object runs, and against that
  relay under the object's own rules (`OH_RELAY`), so the app's side of
  the wire is checked against each.
- **Local mode.** The browser suites run the Pages worker in-process
  over a `Map`, with `OH_OPEN_HOUSE` set. In that mode any key that asks
  is written a subscription and an account of its own and licensed, and
  `local:<subject>` tokens are accepted as sign-ins; the worker honours
  it only for local hosts
  ([security model](security-model.md#the-worker-as-a-whole)).
  `e2e/build.sh` compiles the app against BIP-340's published test key
  pair, so the suites exercise the real handlers, signatures and
  licence check.
- **One device at a time.** The suites' relay is the local Dart one,
  which asks nobody who they are, so there one device at a time is seen
  by presence. The relay's own refusal is proved in `service/do`'s
  tests.
- **TURN.** With `OH_TURN_LOCAL` set as well, `turn` hands out a local
  TURN server with fixed credentials. The rig points it at a coturn it
  starts on `127.0.0.1`, so channels in the suites go through TURN as
  they do in production.
