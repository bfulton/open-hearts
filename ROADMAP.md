# Roadmap

What we plan to build, and what we have chosen to wait on and why. It
is a plan, not a promise. What has shipped is in the
[changelog](CHANGELOG.md). To suggest something, open an issue.

## Waiting on more players

### Rule options

Long-time Hearts players expect some options the game doesn't have yet:

- the Jack of Diamonds counting −10 for whoever takes it;
- a game to 150 points, beside the 50 and 100 there are now;
- passing in no hand at all, not only every fourth.

Each is small to build. But everyone at a live table plays by the same
rules, so each option splits the players waiting into more pools, as the
100-point game already does (`poolTag` in
`packages/table/lib/src/matching.dart`). Fewer players in each pool
means longer waits for a table. So these options wait until the
standard pool has enough players to spare.
