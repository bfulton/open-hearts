# Open Hearts documentation

The documentation is in four kinds, after [Diátaxis](https://diataxis.fr/):
a tutorial to learn by doing, how-to guides for a task at hand,
reference to look things up, and explanation of how and why it works.
What changed, and when, is in the [changelog](../CHANGELOG.md), and
what is planned in the [roadmap](../ROADMAP.md).

## Tutorial

- [Get started](tutorials/getting-started.md): from a fresh clone to
  passing tests and the app running in Chrome.

## How-to guides

Developing:

- [Run the browser suites](how-to/run-the-browser-suites.md)
- [Write a test that stays fast](how-to/write-a-fast-test.md)
- [Reproduce a table fault with the chaos walk and the explorer](how-to/run-the-chaos-walk.md)
- [Benchmark and rate the bots](how-to/benchmark-the-bots.md)
- [Replay a solo game or check a deal by hand](how-to/replay-a-game.md)
- [Add a language](how-to/add-a-language.md)

Releasing:

- [Deploy the site, app and service](how-to/deploy.md)
- [Build a phone release for the App Store or Google Play](how-to/cut-a-phone-release.md)

Operating:

- [Make Cloudflare, Stripe and New Relic match their definitions](how-to/apply-infrastructure.md)
- [Change what every device gets: remote config and service settings](how-to/change-remote-config.md)
- [Mint or rotate the service key](how-to/rotate-the-service-key.md)
- [Register the payment and sign-in webhooks](how-to/set-up-webhooks.md)
- [Delete an account's data on request](how-to/delete-an-accounts-data.md)
- [Look at the day's new pictures](how-to/look-at-new-pictures.md)
- [Handle a report from a player](how-to/handle-a-report.md)
- [Suspend an account, or take its name or picture off](how-to/suspend-an-account.md)
- [End an account, or refund a subscription](how-to/end-an-account.md)
- [Change the terms, the privacy policy or the price](how-to/change-the-terms.md)
- [Handle a report of child sexual abuse material](how-to/handle-abuse-material.md)

## Reference

- [Configuration, secrets and bindings](reference/configuration.md):
  `config/openhearts.json`, secrets, bindings, environment variables,
  remote config, service and relay settings, and the table's clocks.
- [Service handlers and storage](reference/service-api.md): hosts,
  handlers, signed statements, limits and stored rows.
- [Relay tags, kinds and limits](reference/relay.md)
- [check.sh suites, tiers and CI jobs](reference/test-suites.md)
- [Command-line tools](reference/tools.md)

## Explanation

- [How a change reaches a phone](explanation/dev-loop.md): the checks,
  the deploy and how a device picks up a new build.
- [Multiplayer without a game server](explanation/multiplayer.md): how
  devices reach each other, and why through TURN.
- [The fair deal](explanation/fair-deal.md): the mental poker protocol,
  escrow, and what is guaranteed.
- [Live play](explanation/live-play.md): matchmaking, bots, ratings,
  turns, leaving, and the jury.
- [The table's states](explanation/table-states.md): every state a
  table, hand, seat and turn can be in, and how each is decided.
- [The relay](explanation/relay.md): why one object per tag, and what
  it keeps.
- [The service](explanation/service.md): accounts, licences, payment,
  one device at a time, and how it is deployed and watched.
- [Security model](explanation/security-model.md): what a stranger can
  make the system do, and the defences.
- [Screens](explanation/screens.md): layout at every shape and text
  size, motion, colour and screen readers.
- [How Open Hearts is tested](explanation/testing.md): the tiers, what
  makes a suite slow, and what each area's tests hold.
