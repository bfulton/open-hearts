# Benchmark and rate the bots

Use this guide to measure a change to the bots, tune a persona, and rate the strength ladder again.

The bots are in `packages/engine/lib/src/bot.dart`, and the personas and their strengths in `packages/engine/lib/src/persona.dart`. For every tool's flags, see [Command-line tools](../reference/tools.md).

## Before you begin

- Install Dart, and run `dart pub get` in `packages/engine/` and `packages/table/`.
- Run the commands from the repository root.

## Benchmark a change to the bots

1. Before you change anything, run the benchmark and keep its output. It seats four copies of one bot, Westley unless you name another with `--persona`, and plays the same games every time:

   ```bash
   (cd packages/engine && dart run tool/bot_stats.dart --games 2000) > /tmp/before.txt
   ```

1. Make your change, then run the benchmark again:

   ```bash
   (cd packages/engine && dart run tool/bot_stats.dart --games 2000) > /tmp/after.txt
   ```

1. Compare the two. Wins by seat must stay flat, since all four seats run the same bot: a lasting skew is a bug of position, not strategy. Moons shot measures defence: since none of the bots is trying to shoot, every moon is one the other three failed to break up.

   ```bash
   diff /tmp/before.txt /tmp/after.txt
   ```

1. Look for self-destructive plays: plays that took points the bot did not have to take. The counts are a place to look, not a verdict, and `--show` prints whole tricks:

   ```bash
   (cd packages/engine && dart run tool/blunders.dart --tables 1000 --show 12)
   ```

1. Run the engine's tests. They include a tournament of the personas that fails if any falls behind (`packages/engine/test/persona_test.dart`):

   ```bash
   (cd packages/engine && dart test)
   ```

## Tune a persona

1. Measure what each setting is worth on its own: one bot that differs from Westley by a single setting, against three Westleys:

   ```bash
   (cd packages/engine && dart run tool/knobs.dart --games 2000)
   ```

   A setting that costs several points on its own does not belong in a persona.

1. See where each persona lands against the others. Fair share of wins is 25%:

   ```bash
   (cd packages/engine && dart run tool/arena.dart --games 3000)
   ```

   To seat only some personas, name them, such as `--roster "Westley,Romeo,Don Juan,Roxane"`.

## Rate the strength ladder again

Rate the ladder again after a change that moves a strength.

1. Rate every persona at every strength. The tool seats them four at a time at random and fits ratings from the results:

   ```bash
   (cd packages/table && dart run tool/ladder.dart --tables 20000)
   ```

1. Copy the `priors` line it prints into `Persona.priors` in `packages/engine/lib/src/persona.dart`. These are the ratings a bot starts from.

## Check it worked

1. The two outputs show the change you meant: flat wins by seat, and no more moons shot than before.
1. `dart test` passes in `packages/engine/`.
1. After rating the ladder, the strengths' means rise from the bottom rung to the top, and the top rung's mean is 1500, which the fit anchors to.

## Learn more

- [Live play](../explanation/live-play.md#bots): what the personas and their strengths are, and how the ladder is used.
