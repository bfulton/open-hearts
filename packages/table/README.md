# table

The table protocol: signed events, membership, departures, juries and
the sealed deal, over an abstract transport and clock. Its tests run it
on a simulated network, which is a package of its own
([table_sim](../table_sim/)) so that none of it ships. How a live table
works is in [live play](../../docs/explanation/live-play.md), and its
states are in [the table's states](../../docs/explanation/table-states.md).

```bash
(cd ../../crypto/deal && cargo build --release)  # the deal's library
dart test -x slow   # the fast tier
dart test -t slow   # whole sealed games, the chaos walks
```

Its tools, such as the chaos walk and the bots' ladder, are in the
[tools reference](../../docs/reference/tools.md).
