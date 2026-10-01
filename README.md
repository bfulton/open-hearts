# Open Hearts

The best Hearts app we can make, for phones and the web. Free, open
source, no ads.

**Play:** [openhearts.game/play](https://openhearts.game/play) *(domain
not attached yet — see [docs/01](docs/01-dev-loop.md#domains))*
· **Latest dev build:** <https://dev.open-hearts.pages.dev/play>

## Where things are

| | |
|---|---|
| [`packages/engine/`](packages/engine/) | The rules of Hearts and the bots, as pure Dart. No Flutter, no I/O, no clock. Shared by the app and the service |
| [`app/`](app/) | The Flutter app — one codebase, six platforms; web is what ships today |
| [`site/`](site/) | The marketing site, hand-written static HTML |
| [`deploy.sh`](deploy.sh) | Build both, publish to Cloudflare Pages |
| [`docs/`](docs/) | Decisions, and the reasoning behind them |

The site is served at `/` and the app at `/play` from one Cloudflare
Pages deployment.

## Docs

- [01 — The development loop](docs/01-dev-loop.md): publish on every
  commit, drive from a phone, know which build you are looking at
- [02 — Multiplayer without a server](docs/02-multiplayer.md): peer to
  peer over WebRTC, what it costs (nothing), and where the latency goes
- [03 — A deal nobody can rig](docs/03-fair-deal.md): mental poker — a
  shuffle no player controls and hands nobody else can read, with no
  dealer to trust; and where every deal's randomness comes from, a solo
  game's included
- [04 — Live play](docs/04-live-play.md): tap Play, be in a game in
  seconds; bots fill the empty seats and say so; who is allowed to know
  what
- [05 — Screens](docs/05-form-factors.md): phone, tablet, foldable,
  desktop — one product, sized from the space it is given
- [06 — The service](docs/06-service.md): the little that runs on our
  side — identity, entitlement, a juror for an empty room — and how it
  runs locally for end-to-end tests
- [07 — The table's states](docs/07-states.md): every state a table,
  a hand, a turn and a seat can be in, what decides each way out, and
  which are still each device's own judgement

## Where this is going

The finished game is four people playing Hearts with no game server
between them, matched in seconds, on a deal none of them could have
rigged. Roughly in order:

1. **Solo play** against bots — done, and free on every platform forever.
2. **The engine as a package**, shared by the app and the service.
3. **Two measurements before anything is built on them** — taken
   ([measurements](measurements/README.md)). The bot policy as a boolean
   circuit: 3,316 AND gates a play, proven equal to the bot
   ([doc 04](docs/04-live-play.md)). A verifiable 52-card deal in wasm:
   2.1 s critical path on a desktop core with the reference crate, so
   four to six on a phone — implement, then optimise
   ([doc 03](docs/03-fair-deal.md)). The phone's own number is a tap
   away on the dev site.
4. **Four clients, one table.** The protocol is written, its
   departure matrix passes on a simulated network, and a thousand
   seeds of random faults walk its explicit state model without a
   fork or a deadlock ([doc 06](docs/06-service.md), `packages/table`).
   The local relay exists (`service/`, a NIP-01 subset), the same
   clients play a hand over it with real keys and real sockets, and
   the app has live play: one screen before a game, your name and
   avatar behind the icon in its corner and the game you are asking
   for on it — fifty points or a
   hundred, rated or unrated — and **Play live** puts you in the pool
   with however many people are online, which the button says.
   Whoever is waiting on the relay seats each other four to a table
   every five seconds — no matchmaker, the lowest key present hosts
   the round — leftovers first next time, bots at your rating after
   ten; or **Play friends**, a table of your own and a link to send.
   Either way the four of you are on WebRTC data channels, the relay
   beside them, signing in wasm since Dart-to-JavaScript signatures
   cost 100 ms each ([measurements](measurements/README.md)). Rated
   games move a rating, yours and the bots', from results everyone at
   the table signs — and every table is dealt by the verifiable deal (5).
   Four headless browsers prove it on every commit — matched, a hand
   over WebRTC, a browser closed mid-hand, a stalled one booted, a
   leaver (`e2e/`). A deployed build starts on a few public relays —
   the build's, never a setting on the page — our own relay and a few
   public ones, listening on all of them, a table's events written to
   one relay everyone reads (ours preferred while up), what forms a
   table and what goes unanswered to all, so one relay turning on a
   table, or deaf to one player, is not the end of it (`packages/table`,
   `relays.dart`); the local rig points `OH_RELAYS` at its bridges. The deployed
   site's worker mints TURN credentials for the pairs no direct path
   serves (`service/functions/`, doc 06).
   Meanwhile every solo game is kept on the device as a
   record — the deal, the bots, your own passes and plays — and **Copy
   record** on the game-over sheet hands it over as a line of text that
   `packages/engine/tool/replay.dart` turns back into every trick.
   Bot moves are recomputed from it, which is why the bots are
   deterministic. The deal in it is a seed of 256 bits from the
   platform's secure generator, through HMAC-SHA-256 and a Fisher–Yates
   shuffle with no bias, so no deal is out of reach and none follows
   from the ones before it ([doc 03](docs/03-fair-deal.md#where-the-randomness-comes-from)).
5. **The verifiable deal.** Built ([doc 03](docs/03-fair-deal.md),
   "As built"): Barnett–Smart with the Bayer–Groth argument, the
   reference Rust crate compiled once for the browser's wasm and once
   for the Dart VM (`crypto/deal`, `packages/deal`), and the deal run
   as turns of the table protocol at every live table — every seat
   shuffles with a proof, each person's cards are theirs alone to see,
   a departed seat's hand is opened from escrow held by the others and
   the jury, every hand is audited, and the verifier replays it all.
   Every sealed token carries the argument that it is the right one, so
   a pass nobody but its receiver can read is still checked by everyone.
   The one fault no proof can catch — a seat that says it holds the two
   of clubs nowhere — leaves a hand nobody can lead, and such a hand is
   opened where it stands and given up unscored, with the next dealt in
   its place and the seat the opened deal names removed. A bot's hand
   is nobody at the table's to see either: a juror holds each bot seat
   and plays it ([doc 04](docs/04-live-play.md), "Playing a seat
   nobody holds").
6. **Live play** ([doc 04](docs/04-live-play.md)) — presence,
   matchmaking, seat handover, the jury: built, all three of its roles
   — breaking a deadlock, holding the escrow of the deal, and playing
   the seats nobody holds. A bot seat is a seat whose device is a
   juror: its key drawn like a person's instead of hashed from public
   values, one juror per seat so that nobody holds enough to take the
   last hand by subtraction, its escrow among jurors alone so no
   player holds a piece, another juror taking it over when its holder
   goes — and, with nobody left who could open it mid-hand, the game
   ending unscored after twenty seconds, a connection failure: "juror
   quorum lost" — and the audit publishing its secret so the verifier
   still checks every bot move was the policy's. A table short of jurors to
   hold its bot seats calls for them and waits rather than dealing a
   hand everyone can see, and what answers on an empty night is a
   bench of jurors of last resort rather than one, since one cannot
   make the four a held seat needs. It costs about 30 KB a seat a hand
   on the relay and it costs the live check: a bot's move is a signed
   event now, and true only at the audit rather than at the turn. Seating goes by pace as well as rating, so slow players find
   each other; a pace is the one number about a game no two peers can
   agree on, so each device measures its own and states it the way it
   states a rating.
7. **Landscape**, then **tablet**, then **iPhone Duo**
   ([doc 05](docs/05-form-factors.md)) — built, all three, and all
   three chosen from the space the table is given rather than from the
   device. A phone on its side gets the second composition, the hand
   shorter and wider under the same slim header. Past a width the
   table wants it stops spreading and is centred with its rail as one,
   the cards grow with the felt instead of staying a phone's size and
   the type round them grows by as much, the table sits low in a felt
   with height to spare, and what is left over is a rail showing what
   has gone — the fifty-two with the played ones struck through. A turn
   mid-hand keeps the game, and so does a fold.
8. **Live play is a subscription** — $5.99 a year, paid up front
   ([doc 06](docs/06-service.md)). The licence, the gate, and buying on
   the web through Stripe are built, and so is sharing a subscription
   across your devices: five to a household, brought in by a code one
   of them shows and the next one's camera reads. Buying on a phone is
   the store's own subscription, and both halves are built — the app's
   store sheet and restore, and the service's checks of an App Store
   signed transaction and a Play purchase token, with each store's
   renewal notifications — waiting on the products being made in the
   stores and the next item. Web subscribers cancel in Stripe's billing
   portal. Provider
   sign-in, so a lost phone is recovered by signing in, is built on the
   service's side and waits on a Google client id and an Apple service
   id for the app's.
9. **The stores.** And with them the deal's native library bundled
   into the phone builds, as the web build ships its wasm: every live
   table is sealed, so a build without it plays alone. Android's is
   built (`crypto/build_android.sh`, packed into the APK, and a release
   refuses to build without it); iOS's needs a Mac to build and link.

### Backlog

Ideas agreed on and not yet placed in the order above.

- **The bot inside the computation**, which would give back the live
  check a juror-held seat gives up — a bot's move derived by everyone
  again rather than taken on a stranger's signature until the audit.
  **The computation is built and works**
  ([ot](measurements/ot/README.md)): the bot's own policy, garbled,
  over a hand split between two parties neither of whom can see a
  card, picking the card the bot picks — with a garbler who tampers
  with a row caught by the MAC the row carries. One decision is 1.84
  MB and 441 ms of wasm for both parties; a hand is 33.4 MB and eight
  seconds, which is 56 seconds of a 5 Mbit/s uplink against sixty of
  play. It fits, and only because the circuit is built at the turn
  rather than before the hand. What it does not fit is a seat that is a
  bot from the deal: 28 MiB a hand, 47 seconds of a 5 Mbit/s uplink
  against a hand of sixty, and 141 at three bot seats. The standing
  buffer that looks like the answer buys latency rather than total — it
  spends only on plays a bot really makes, which saves nothing when a
  bot plays every trick. So the jury plays bot seats and this stays a
  measurement: the one that priced the alternative well enough to
  choose against it. If a protocol lands several times smaller, the
  ledger changes.

## Developing

```bash
crypto/deal/build.sh                # the deal's cryptography, for the VM and the browser (Rust)
crypto/schnorr/build.sh             # signatures for the VM: the relay, the juror, the tests (Rust)
cd packages/engine && dart test     # the rules, the bots, 200 seeded games
cd packages/deal && dart test       # the deal's primitives, and a hand's deal among four sessions
cd packages/table && dart test      # the protocol on a simulated network, sealed tables included
cd service && dart test             # the local relay, and a hand played over it with real signatures
cd service && OH_RELAY=js dart test # the same suite, against the object's relay
node --test service/do/*.test.mjs   # that relay's own tests, and the sockets under it
node --test service/functions/*.test.mjs  # the site's handlers: TURN, licences, the shop
node --test e2e/deal_worker.test.mjs      # the page's deal worker, against the committed wasm
node --test e2e/offline_worker.test.mjs   # the service worker that keeps the app for a load with no network
cd app && flutter test              # the widgets
cd app && flutter run -d chrome
cd app && flutter build apk --release  # needs app/android/key.properties (below)

./e2e/build.sh                      # the app as the suites drive it
node e2e/flows.mjs                  # every flow one device can drive, in a browser
node e2e/run.mjs                    # four browsers at one table, over the local relay
node e2e/escrow.mjs                 # a bot seat's juror goes, and the escrow opens the seat
node e2e/offline.mjs                # no network, no relays, no worker: solo still plays, every wait ends in words
```

An Android release is signed with the release key named in
`app/android/key.properties` — `storeFile`, `storePassword`,
`keyAlias`, `keyPassword` — which is never checked in and is written
from the store's secrets wherever a release is built. Without it a
release build stops and says so rather than signing with the debug
key; a debug build needs none.

The deal ([doc 03](docs/03-fair-deal.md)) is one Rust crate built
twice by `crypto/deal/build.sh`: a cdylib the Dart VM loads over FFI —
the table and app tests, the verifier and the service's juror find it
at `crypto/deal/target/release/` — and a
wasm the browser loads, committed at `app/web/deal.wasm` so the web
build needs no Rust. The page loads it twice: once for the quick
calls, and once in a Web Worker, `app/web/deal_worker.js`, for the
slow ones — a shuffle, its check, a seat's tokens — so that the screen
keeps drawing while they are made (`packages/deal`, `work.dart`). None
of those is ever made on the page instead: a page whose worker does not
start plays no live table.
Building needs a stable Rust with the
`wasm32-unknown-unknown` target; the reference crate is a git
dependency pinned by revision. `crypto/schnorr` is the browser's
signature wasm built for the VM instead: without it the relay, the
juror and the tests sign and check in pure Dart at seventeen
milliseconds a signature, which a table's traffic turns into most of
a core.

Publish the current commit to the dev branch page:

```bash
./deploy.sh         # needs CLOUDFLARE_TOKEN and CLOUDFLARE_ACCOUNT_ID
```

Live play is a subscription ([doc 06](docs/06-service.md)), and a build
only takes a licence from the service it was compiled to expect. Mint
the pair once with `cd service && dart run bin/service_key.dart`: the
public half goes in `OH_SERVICE_KEY` where `deploy.sh` can read it, the
secret half into the project's secrets as `OH_SERVICE_SECRET` and
nowhere else. The store is Cloudflare KV bound as `OH_STORE`, and the
shop is `OH_STRIPE_SECRET`, `OH_STRIPE_PRICE` and
`OH_STRIPE_WEBHOOK_SECRET`. A build published without them has live
play shut and says what it costs — which is the right way round for a
missing key, and is what the browser suites prove by supplying their
own (`e2e/build.sh`).

### Languages

The app speaks English, Spanish, Brazilian Portuguese, German and
French, chosen from the device's own language, with English where it
speaks none of them; `?lang=de` in the address chooses instead. Every
sentence on the screen, and every one a screen reader says, is a message
in `app/lib/l10n/app_en.arb` with a description of where it appears,
translated in the `.arb` beside it; `flutter pub get` generates the
class the widgets read them through (`app/l10n.yaml`). The engine keeps
its own English — a card's name, a way to pass — for logs and tests, and
`app/lib/l10n/l10n.dart` says those in the player's language.

A new language is one more `.arb`. `app/test/l10n_test.dart` holds every
translation to the English's blanks, gives every card and rule a name
of its own in it, and lays out every page in it on a 320-pixel phone and
an ordinary one, in Roboto rather than the test font, failing on
anything that overflows or is cut short. The English there is held to
what it was, word for word: the browser suites find the table by it.
The translations are a first pass and want a native speaker's read.

### The engine is the point

`packages/engine/` has no Flutter imports and no notion of time. That is
deliberate, and it buys three things:

- the rules are testable without a screen — a full game runs in
  microseconds, so the suite plays 200 of them on every commit;
- pacing lives in `GameController`, so the engine never has to know what
  an animation is;
- every peer in a future multiplayer game can run the same referee. See
  [doc 02](docs/02-multiplayer.md).

Two transitions do not happen on their own — `collectTrick()` and
`nextHand()`. A finished trick sits on the table until the caller sweeps
it, which is what lets the UI hold a beat without the engine owning a
clock.

### The bot

`packages/engine/lib/src/bot.dart` is heuristics, not search: named rules you can
read and argue with. That is worth more than strength right now, because
a bot whose mistakes are legible is one you can fix. The interface is two
methods over a `BotView` of public information, so a search player can
replace it without touching anything else.

The suite proves it never breaks a rule; it cannot prove it plays well.
That is what the benchmark is for:

```bash
cd packages/engine && dart run tool/bot_stats.dart --games 2000
```

```
wins by seat        : [538, 486, 518, 504]   (fair share 500)
mean final score    : [75.5, 76.7, 77.2, 76.5]
queen taken by seat : [5057, 5193, 5207, 5168]
moons shot          : 1453  (7.0% of hands)
```

All four seats run the same bot, so **wins by seat should be flat** — a
persistent skew is a positional bug rather than strategy. And **moons
shot** gauges attack against defence: every bot runs at the moon on a
hand that is plainly a shot, and with four of them one lands in about
one hand in fourteen; before any bot shot, defence alone had it at 1.7%.
Run it before and after touching `bot.dart`.

The bots have names and temperaments (`persona.dart`), and each comes at
nine strengths, so a person is seated with bots near their own rating:
the top is the whole policy, and each rung down takes away one thing a
player learns, down to a first game that leads its lowest card and
passes its highest three. What each rung is worth is measured, not
guessed — `tool/knobs.dart` takes one setting away at a time, and
`packages/table/tool/ladder.dart` plays the whole ladder against itself
and fits the ratings each rung starts from ([doc
04](docs/04-live-play.md)).

Known gaps, in the order they are worth closing: the bot does not read
what an opponent's discards say about their hand, and counts the cards
that have gone only to know which of its own are sure winners.
`tool/blunders.dart` lists the plays that took points they did not have
to, with hindsight, by persona and kind — the place to look for the
next rule.

## Licence

MIT. See [LICENSE](LICENSE).
