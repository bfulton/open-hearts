# Look into a live game that went wrong

Use this guide when a player says a live game stalled, said it was reconnecting, or ended because the game's server stopped answering. Each side of a table keeps its own account of it, where it runs. `./oh table` puts them into one timeline:

| Side | What it says | Where it is kept |
|---|---|---|
| The house | Its traces: each table it is woken for, every seat it plays, each hand dealt, each seat given up and how, and how the game came out. Each line of a table's is headed by the first eight characters of its id. | Workers Logs, the `containers` dataset |
| The relay | Each socket on the table's tag opening and closing: as a device or the house, the close code, whether it closed cleanly, and how long it was open (`socketLine` in `service/do/relay.mjs`). | Workers Logs, from the relay worker |
| The house's object | Each wake of the house, starting it, how long it took to answer, restarting it under a new deploy, and stopping it (`service/do/bench.mjs`). | Workers Logs, from the relay worker |
| The player's device | A game it lost, a deal it could not run, or its line down for two minutes: where its table stood (`TableRules.describe`: the log's length, the hand, what was owed and by whom, the seats given up), and its line to the referee (open or down, when it last heard, drops, drops for silence, what it has sent that the log has not carried). | New Relic, as a JavaScript error named `live: …` |

None of it holds a name, and the device's report holds no key and no card. A device reports only from the game on the web: the phone apps report nothing ([privacy](../../site/pages/privacy.html)).

## Before you begin

- Install Node.
- Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. The token needs Workers Observability: Read.
- For the device's side, export `NEW_RELIC_API_KEY`, a User key, and `NEW_RELIC_ACCOUNT_ID`. Without them the timeline leaves the device out and says so.
- Find the table's id: the end of the address the player's game was at, `play.openhearts.game/table/<id>`. The first eight characters are enough. A device's report in New Relic names the table by those eight too.

## See the timeline

```bash
./oh table 83167bb6
```

It looks back three days; `--days` changes that, to at most 30. Workers Logs keeps less than that, so a game older than a few days may show nothing.

## Read it

- **The device was cut off.** Its report says its line is down, or the relay shows its socket closing unclean (code 1006) while the house and the others go on. Nothing heard back from the relay for ten seconds, with what it sent unanswered, is the device's own line down, not the table. The game waits for the line and says so ([live play](../explanation/live-play.md#a-device-cut-off-from-the-table)). Look for the line coming back: the relay opens a socket for it again, and the device reads the log from where it was. A seat whose connection stays closed for the table's silence at its turn is given to a bot.
- **The house stopped answering.** The house's traces stop, the relay shows its socket closing, and the device's report says `game lost: the house let a turn run out`: a bot's move or a step of the deal owed by the house ran past its deadline and its grace, and the table failed. Look at the house's object around then: was it stopped (`stop`), did it not come up (`not up`), or was it restarted under a new deploy (`restart`)? A house started again reads the log from its start and goes on, so a restart in good time loses nothing.
- **The house would not serve the table.** The house's traces say `not served` and why (a seat's licence, or a rated table the house did not seat), the log has one entry of the house's, a result saying `failed`, and the game ended there, at once, with the device's report saying `game lost: the house let a turn run out`, which is the report's wording for any table that failed. Nobody is rated on it. The house is woken for it once ([when the house will not serve a table](../explanation/live-play.md#when-the-house-will-not-serve-a-table)).
- **The house was never woken.** No `woken` line from its object for the table, and the house's traces never name it. Look for the object's `not woken` lines, which say why. A table whose start names another house never starts: the referee does not take that start.
