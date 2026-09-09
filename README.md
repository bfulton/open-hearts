# Open Hearts

The best Hearts app we can make, for phones and the web. Free, open
source, no accounts, no ads.

**Play:** [openhearts.game/play](https://openhearts.game/play) *(domain
not attached yet — see [docs/01](docs/01-dev-loop.md#domains))*
· **Latest dev build:** <https://dev.open-hearts.pages.dev/play>

## Where things are

| | |
|---|---|
| [`app/`](app/) | The Flutter app — one codebase, six platforms; web is what ships today |
| [`app/lib/engine/`](app/lib/engine/) | The rules of Hearts as pure Dart. No Flutter, no I/O, no clock |
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

## Developing

```bash
cd app
flutter test        # rules engine + widget tests
flutter analyze
flutter run -d chrome
```

Publish the current commit to the dev branch page:

```bash
./deploy.sh         # needs CLOUDFLARE_TOKEN and CLOUDFLARE_ACCOUNT_ID
```

### The engine is the point

`app/lib/engine/` has no Flutter imports and no notion of time. That is
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

`app/lib/engine/bot.dart` is heuristics, not search: named rules you can
read and argue with. That is worth more than strength right now, because
a bot whose mistakes are legible is one you can fix. The interface is two
methods over a `BotView` of public information, so a search player can
replace it without touching anything else.

The suite proves it never breaks a rule; it cannot prove it plays well.
That is what the benchmark is for:

```bash
cd app && dart run --define=GAMES=2000 tool/bot_stats.dart
```

```
wins by seat        : [503, 537, 500, 502]   (fair share 500)
mean final score    : [74.7, 75.2, 75.9, 75.4]
moons shot          : 373  (1.7% of hands)
```

All four seats run the same bot, so **wins by seat should be flat** — a
persistent skew is a positional bug rather than strategy. And **moons
shot** gauges defence: nothing here tries to shoot, so every moon is one
the other three failed to break up. Adding moon defence took that number
from 3.2% to 1.7%. Run it before and after touching `bot.dart`.

Known gaps, in the order they are worth closing: the bot never tries to
shoot the moon itself, does not count the cards that have gone, and does
not read what an opponent's discards say about their hand.

## Licence

MIT. See [LICENSE](LICENSE).
