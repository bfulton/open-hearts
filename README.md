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
  dealer to trust
- [04 — Live play](docs/04-live-play.md): tap Play, be in a game in
  seconds; bots fill the empty seats and say so; who is allowed to know
  what
- [05 — Screens](docs/05-form-factors.md): phone, tablet, foldable,
  desktop — one product, sized from the space it is given
- [06 — The service](docs/06-service.md): the little that runs on our
  side — identity, entitlement, a juror for an empty room — and how it
  runs locally for end-to-end tests

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
   the app has live play: **Play live**, pick rated or unrated, and
   whoever is waiting on the relay seats each other four to a table
   every five seconds — no matchmaker, the lowest key present hosts
   the round — leftovers first next time, bots at your rating after
   ten; or host a four-letter code for friends. Either way the four of
   you are on WebRTC data channels, the relay beside them, signing
   in wasm since Dart-to-JavaScript signatures cost 100 ms each
   ([measurements](measurements/README.md)). Rated games move a
   rating, yours and the bots', from results everyone at the table
   signs — and every table is dealt by the verifiable deal (5).
   Four headless browsers prove it on every commit — matched, a hand
   over WebRTC, a browser closed mid-hand, a stalled one booted, a
   leaver (`e2e/`). A deployed build starts on a few public relays,
   listening on all of them and writing to one at a time, so one relay
   turning on a table is not the end of it (`packages/table`,
   `relays.dart`); `DEV_RELAY` takes a comma-separated list.
   Meanwhile every solo game is kept on the device as a
   record — the deal, the bots, your own passes and plays — and **Copy
   record** on the game-over sheet hands it over as a line of text that
   `packages/engine/tool/replay.dart` turns back into every trick.
   Bot moves are recomputed from it, which is why the bots are
   deterministic.
5. **The verifiable deal.** Built ([doc 03](docs/03-fair-deal.md),
   "As built"): Barnett–Smart with the Bayer–Groth argument, the
   reference Rust crate compiled once for the browser's wasm and once
   for the Dart VM (`crypto/deal`, `packages/deal`), and the deal run
   as turns of the table protocol at every live table — every seat
   shuffles with a proof, each person's cards are theirs alone to see,
   a departed seat's hand is opened from escrow held by the others and
   the jury, every hand is audited, and the verifier replays it all.
   Bots' hands are open to the table until the bot plays inside the
   computation ([doc 04](docs/04-live-play.md)).
6. **Live play** ([doc 04](docs/04-live-play.md)) — presence,
   matchmaking, seat handover, the jury: built, its deadlock role and
   its escrow of the deal.
7. **Landscape**, then **tablet**, then **iPhone Duo**
   ([doc 05](docs/05-form-factors.md)).
8. **The stores.**

### Backlog

Ideas agreed on and not yet placed in the order above.

- **A time bank per hand.** The Boot button only removes someone who is
  absent; a player who takes fourteen seconds over every card is never
  booted and costs the table three minutes a hand. A few seconds of
  grace per card plus a bank of thinking time per hand, and Boot the
  moment the bank is empty. A change to the boot rule in
  [doc 04](docs/04-live-play.md), so a design conversation first.
- **A pace history**, kept with the rating from the same signed
  results, and **matchmaking by pace**, so slow players find each other.
- **The bot inside the computation**, so a bot's hand is open to
  nobody ([doc 04](docs/04-live-play.md), "Playing a seat nobody
  holds"); until then bots' hands are open to the table.
- **Two holes only a modified client can open** ([doc
  03](docs/03-fair-deal.md), "As built"): a holder who declares the
  2♣ nowhere — the remedy is an early audit and a redeal without the
  liar — and a pass sealed with garbage — a verifiable encryption, or
  a complaint the passer answers by opening the cards in public.

## Developing

```bash
crypto/deal/build.sh                # the deal's cryptography, for the VM and the browser (Rust)
crypto/schnorr/build.sh             # signatures for the VM: the relay, the juror, the tests (Rust)
cd packages/engine && dart test     # the rules, the bots, 200 seeded games
cd packages/deal && dart test       # the deal's primitives, and a hand's deal among four sessions
cd packages/table && dart test      # the protocol on a simulated network, sealed tables included
cd app && flutter test              # the widgets
cd app && flutter run -d chrome
```

The deal ([doc 03](docs/03-fair-deal.md)) is one Rust crate built
twice by `crypto/deal/build.sh`: a cdylib the Dart VM loads over FFI —
the table and app tests, the verifier and the service's juror find it
at `crypto/deal/target/release/`, or where `DEAL_LIB` points — and a
wasm the browser loads, committed at `app/web/deal.wasm` so the web
build needs no Rust. Building needs a stable Rust with the
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
cd packages/engine && dart run --define=GAMES=2000 tool/bot_stats.dart
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
