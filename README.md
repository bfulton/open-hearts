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
   circuit: 3,676 AND gates a play, proven equal to the bot
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
   the app has a live table: **Play live**, host a four-letter code or
   join one, and the four of you are on WebRTC data channels with the
   relay as fallback, signing in wasm since Dart-to-JavaScript
   signatures cost 100 ms each ([measurements](measurements/README.md)).
   Still to come: the end-to-end suite in real browsers, and a relay
   that is not on localhost. Meanwhile every solo game is kept on the
   device as a
   record — the deal, the bots, your own passes and plays — and **Copy
   record** on the game-over sheet hands it over as a line of text that
   `packages/engine/tool/replay.dart` turns back into every trick.
   Bot moves are recomputed from it, which is why the bots are
   deterministic.
5. **The verifiable deal.**
6. **Live play** ([doc 04](docs/04-live-play.md)) — presence,
   matchmaking, seat handover, the jury.
7. **Landscape**, then **tablet**, then **iPhone Duo**
   ([doc 05](docs/05-form-factors.md)).
8. **The stores.**

## Developing

```bash
cd packages/engine && dart test     # the rules, the bots, 200 seeded games
cd app && flutter test              # the widgets
cd app && flutter run -d chrome
```

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
wins by seat        : [503, 510, 498, 533]   (fair share 500)
mean final score    : [76.5, 76.2, 76.5, 75.7]
queen taken by seat : [5146, 5078, 5035, 4926]
moons shot          : 1633  (8.1% of hands)
```

All four seats run the same bot, so **wins by seat should be flat** — a
persistent skew is a positional bug rather than strategy. And **moons
shot** gauges attack against defence: every bot runs at the moon on a
hand that is plainly a shot, and with four of them one lands in about
one hand in twelve; before any bot shot, defence alone had it at 1.7%.
Run it before and after touching `bot.dart`.

Known gaps, in the order they are worth closing: the bot does not read
what an opponent's discards say about their hand, and counts the cards
that have gone only to know which of its own are sure winners.
`tool/blunders.dart` lists the plays that took points they did not have
to, with hindsight, by persona and kind — the place to look for the
next rule.

## Licence

MIT. See [LICENSE](LICENSE).
