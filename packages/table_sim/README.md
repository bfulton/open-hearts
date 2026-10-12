# table_sim

The [table](../table/) over a simulated network, for tests and tools: a
virtual clock that plays a whole game in milliseconds, a network that
loses, delays and reorders what it carries, jurors, scripted people,
fake signatures, seats that lie, and the walks that check what the
table does under all of it. How the table is tested on it is in
[testing](../../docs/explanation/testing.md).

Nothing that ships has this package in it. The table, the app and the
service take it as a dev dependency, for their tests and tools only, and
their analysis fails if code they ship imports it. The table takes
BIP-340 signatures and nothing else; making a `FakeSigner` is what puts
a check for the simulator's signatures in front of that, in the process
that made one.

```bash
dart test   # its own tests; the table's are where the table is
```
