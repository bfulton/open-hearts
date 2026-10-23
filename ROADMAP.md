# Roadmap

What we plan to build, and what we have chosen to wait on and why. It
is a plan, not a promise. What has shipped is in the
[changelog](CHANGELOG.md). To suggest something, open an issue.

## Planned

### A dashboard of production's metrics

The service and the relay already count what they do, in Workers
Analytics Engine ([Watching it run](docs/explanation/service.md#watching-it-run)):
each request to the service by handler, status and time taken, and each
relay object's connections, events, deliveries and refusals. Today
they are read only by asking the Analytics Engine SQL API. A dashboard
would show them over time in one place, beside New Relic's checks of
whether the site, the app and the relay are up, so that a slow handler,
a rise in refusals or a quiet day is seen without asking. Like the
counts themselves, it would show nothing about anybody.

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
