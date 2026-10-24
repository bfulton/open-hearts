# Look into a live game that went wrong

Use this guide when a player says a live game stalled, said it was reconnecting, or ended with "Connection failure". Each side of a table keeps its own account of it, where it runs. `./oh table` puts them into one timeline:

| Side | What it says | Where it is kept |
|---|---|---|
| The backup jurors | Their traces: every turn they open, settle and play, who they hear and when, and a stall's state when they stop moving. Each line of a table's is headed by the first eight characters of its id. | Workers Logs, the `containers` dataset |
| The relay | Each socket on the table's tag opening and closing: as a device or a backup juror, the close code, whether it closed cleanly, and how long it was open. | Workers Logs, from the relay worker |
| The backup jurors' object | Each call that woke them, starting them, how long they took to answer, and stopping them. | Workers Logs, from the relay worker |
| The player's device | A game it lost, or its line down for two minutes: where the table stood, how many of the others and the jurors it heard and how long ago, whether it was cut off, and its line to the relays (open sockets, when one was last heard, drops, drops for silence). | New Relic, as a JavaScript error named `live: …` |

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

- **The device was cut off.** Its report says `cut off now`, or the relay shows its socket closing unclean (code 1006) while the jurors go on playing. Nothing heard back from the relay for ten seconds, with what it sent unanswered, is the device's own line down, not the table. The game waits for the line and says "Your connection is down — reconnecting" ([live play](../explanation/live-play.md#a-device-cut-off-from-the-table)). Look for the line coming back: the relay opens a socket for it again, and the jurors hear it.
- **The jurors went.** The jurors' traces stop, the relay shows their sockets closing, and the device's report says `line up` with the jury not heard for half a minute and more. The game ends "juror quorum lost" twenty seconds after that. Look at the jurors' object around then: were they stopped (`stop`), did they not come up (`not up`), or were they restarted under a new deploy (`restart`)?
- **The jurors were never woken.** No `woken` line from their object, and the table's calls for a juror in the jurors' traces go unanswered. Look at the relay's own errors in Workers Logs (`backup jurors not woken`).
