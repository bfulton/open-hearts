# 09 — Testing

What runs, how long it takes, and why it takes no longer. Every suite
is in `./check.sh`; CI runs the same suites in jobs side by side
(`.github/workflows/ci.yml`).

## Running them

```bash
./check.sh quick            # what you touched since origin/claude/launch-punch-list, fast tiers
./check.sh quick main       # … since another base
./check.sh full             # everything, the browser suites too, side by side
./check.sh table app        # the suites named
./check.sh list
```

`quick` reads the paths that differ from the base — commits since the
merge base, the index, the working tree, new files — and runs the suites
those paths are in, each at its fast tier: `app/` analyzes and runs the
app tests whose imports reach a changed file
(`app/tool/affected_tests.mjs`, all of them for a change to the
pubspec, the words or the test config), `packages/table` its fast tier,
`service/functions` the handlers' node tests, `site/` the site's, and so
on. It checks what a change touches; `full` checks what that touches in
turn — the service and the app over a changed `packages/table` — and is
what CI runs. Each prints a table of suites, verdicts and times; each
suite's output is in `build/check/<suite>.log`.

## Tiers

`dart test` and `flutter test` run everything a package has. The table's
long cases — whole sealed games played out under every departure, the
chaos walks past the first eight seeds — carry the tag `slow`
(`packages/table/dart_test.yaml`): `dart test -x slow` is the fast tier
`quick` runs, `dart test -t slow` the rest. Nothing is only in the slow
tier that a fast run would have caught sooner: a tag moves a test, it
never drops one. The app's fits matrix — every shape, text size and
language — is its `slow` (`app/dart_test.yaml`), which `quick` leaves to
`full`.

## Where the time went

Measured on a machine of four cores, each suite alone with nothing
else running, before and after; seconds of wall clock. Cold: the
deal's answers not yet kept on disk; warm: kept.

| Suite | Before | After |
|---|---:|---:|
| `packages/engine` | 20 | 13 |
| `packages/deal` | 62 | 21 cold, 6 warm |
| `packages/table` | 1 410 | 165 cold, 79 warm |
| `packages/table -x slow` | — | 33 |
| `service` (Dart relay) | 267 | 92 |
| `service` (`OH_RELAY=js`) | 194 | 71 |
| `app` (`flutter test`) | 211 | 139 |
| node tests | 21 | 21 |
| `e2e/build.sh` | 76 | 72, 0 unchanged |
| `e2e/site.mjs`, `move.mjs` | 28 | 28 |
| `e2e/escrow.mjs` | 73 | 47 |
| `e2e/offline.mjs` | 511 | 126 |
| `e2e/flows.mjs` | 823 | 169 |
| `e2e/run.mjs` | 452 | 272 |
| **one after another** | **4 148** | **1 230** |
| **`./check.sh full`** | — | **≈ 750** |

`full` is held to twelve minutes or so by the machine, not the
waiting: the suites ask for some 2 600 seconds of CPU between them,
two thirds of it the browsers drawing the app without a GPU, and four
cores give that back no sooner than eleven minutes. CI spreads the same
suites across runners (below) and finishes when the longest does.

The slow ones, and why:

- **The table's sealed games** (`chaos_sealed` 573 s, `deal_worker`
  493 s, `sealed` 407 s; the files that deal sealed made 45 of the
  suite's 46 minutes of test time). Not the clock: the simulator runs on its own
  (`VirtualClock`), and a table plays three minutes of table time in
  milliseconds. The time was the deal's cryptography, run for real: a
  shuffle proof is checked by every person and juror at the table and
  again by the verifier, and the tests of a file play the same seeds
  into one departure after another. 95% of a sealed walk was calls into
  the library, nearly all of them answered before.
- **The service's games over real sockets** (`two_tables`, the jury
  over the relay: 5 of its 7 minutes). On the wall clock on purpose —
  real relays, real signatures — and played to fifty, a person's
  thinking a quarter of a second at a time.
- **The app's widget tests**: rendering, the fits matrix above all
  (seven shapes, four text sizes, five languages, alone and live). No
  real-time waits; pumped on the test clock already.
- **The browser suites**: real time by nature, and most of it the
  table's own beats — a bot thinking for half a second to a second and a
  half, each trick held for one — and its clocks: two minutes of
  silence before a gone person is ruled on, a forty-five second bank
  before Boot. A game alone to fifty was three and a half minutes of
  `flows.mjs`, a live one more than two; the four-browser run waited
  three minutes for clocks.
- **The browser drawing.** Headless Chromium draws the app in software,
  and a page with something always moving — the folding heart, the turn
  pill breathing — keeps a core busy for as long as it is open.

## What keeps it fast

- **The deal's answers, remembered.** Sealed tests take the library
  through `rememberedCrypto()` (`package:deal/memo.dart`): each call is
  answered by the library once, and from memory after. The answers are
  kept on disk beside the library that gave them,
  `crypto/deal/target/memo/<the library's hash>`, for the next file and
  the next run; a rebuilt library answers everything afresh, and
  `OH_DEAL_MEMO=off` keeps nothing. A proof changed by a byte is new
  bytes, asked anew, so a test of a bad proof still sees the library say
  no. The service's tests on the wall clock keep answers in memory only,
  so a device's own shuffle still costs what it costs there. CI caches
  the directory under the deal's sources.
- **Files side by side.** The table and the service run four files at
  once (`dart_test.yaml`), the app four (`flutter test -j 4`). A file's
  tests run one after another, so a long file is split: the sealed
  table's tests are three files, the jury over the relay two.
- **A game as long as the point needs.** The service's two tables play
  to 27, which is still two hands at least; a browser flow that has to
  see a game's end plays one hand (`?e2e=1&target=1`).
- **The browser suites side by side.** Each starts its relay on a port
  of its own and names it in every address it opens (`?relay=PORT`,
  which only a build served from this machine reads). `flows.mjs` and
  `offline.mjs` share their flows among three workers, each with a rig
  of its own, so no flow meets another (e2e/README.md;
  `--serial` or `--jobs N` to change it). The app is
  built once (`e2e/build.sh`, not again until its sources change), and
  the relay and the jurors are compiled ahead of time once, as the
  bench's container runs them.
- **The table's beats and clocks, shortened where a suite waits on
  them.** The browser suites open the app at a tenth of its tables'
  beats (`?pace=0.1`); where a cell waits on a table's clock the rig's
  handlers serve a remote config that sets it to the least it may be —
  half a minute of silence, a bank of ten seconds — through the same
  `config` route the operator uses. The cells are the same; the waits
  are shorter. The device's own waits on the network are the build's,
  which `offline.mjs` times.
- **Pages that stand still.** A flow that does not look at motion opens
  its pages asking for reduced motion, which the app honours, at one
  device pixel to the point; a page waiting on a turn then costs a
  twentieth of the CPU. The flows that look at motion or at pixels — a
  hand alone, the thumb's reach — keep both.

Every shortened test was checked against its own failure: with no
escrow piece ever released, a bad seal let through, no second deal, or
the end of a game left unshown, the tests that hold those things fail
as before.

## A test that stays fast

- Wait on the condition, never a while: the simulator's `runUntil`, a
  stream's `first` with a timeout, `waitFor` in the browser suites.
- Put clocks on the `VirtualClock` (packages/table) or `fake_async`
  (the app). A test that waits out a real timer is a test of the
  machine.
- A sealed table takes `rememberedCrypto()`.
- A test that has to be long is tagged `slow`, in a file of its own if
  it would hold a whole file up.
