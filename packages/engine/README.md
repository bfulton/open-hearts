# engine

The rules of Hearts and the bots that play them, in pure Dart: no
Flutter, no I/O, no clock. The app's solo game and every live table play
by it.

```bash
dart test                                 # rules, bots, seeded games
dart run tool/bot_stats.dart --games 2000 # the bots' benchmark
```

`tool/` also holds `blunders.dart` (plays that took avoidable points)
and `knobs.dart` (what each strength setting is worth). How the bots
are rated is in the [README](../../README.md#the-bots).
