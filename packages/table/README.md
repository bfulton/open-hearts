# table

The table protocol: signed events, membership, departures, juries and
the sealed deal, over an abstract transport and clock, with a simulated
network to test it on. How a live table works is
[doc 04](../../docs/04-live-play.md); its states are
[doc 07](../../docs/07-states.md).

```bash
(cd ../../crypto/deal && cargo build --release)  # the deal's library
dart test -x slow   # the fast tier
dart test -t slow   # whole sealed games, the chaos walks
```

`tool/` holds what the tests do not: `chaos.dart` walks tables through
random failures, many seeds at a time, and `walk.dart` walks one with
every trace kept; `ladder.dart` rates the bots; and `time_to_deal.dart`
measures a sealed deal.
