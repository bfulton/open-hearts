# table

The table protocol: signed events, membership, departures, juries and
the sealed deal, over an abstract transport and clock, with a simulated
network to test it on. How a live table works is in
[live play](../../docs/explanation/live-play.md), and its states are in
[the table's states](../../docs/explanation/table-states.md).

```bash
(cd ../../crypto/deal && cargo build --release)  # the deal's library
dart test -x slow   # the fast tier
dart test -t slow   # whole sealed games, the chaos walks
```

Its tools, such as the chaos walk and the bots' ladder, are in the
[tools reference](../../docs/reference/tools.md).
