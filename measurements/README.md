# Measurements

Numbers the design rests on, each with the code that produced it and
the command that reproduces it. The docs quote them; this is where they
come from.

| | Question | Answer, in short |
|---|---|---|
| [`shuffle/`](shuffle/README.md) | What does a verifiable 52-card shuffle cost, native and in wasm? | doc 03: fast enough to deal every hand |
| [`sign/`](sign/README.md) | How long do BIP-340 signatures take in a browser? | 100 ms in Dart-to-JavaScript, 0.6 ms in wasm; the web app uses the wasm |
| [`channel/`](channel/README.md) | What does a WebRTC data channel carry, and what does carrying it cost the table? | doc 04: the channel is not the constraint; a hand affords about 700 bytes a gate, and bulk must not share the table's channel |
| [`ot/`](ot/README.md) | What does it cost to run the bot over a hand nobody can see — and does it work? | doc 04: it works, and one decision is 1.84 MB and 441 ms of wasm; a hand is 33.4 MB and eight seconds, which fits a p50 hand with nothing to spare |
| [`relay/`](relay/README.md) | What does the relay path carry — the only path a juror has? | doc 04: 1.79x sealed and signed, and 390 bytes a gate against the channel's 700; above that a juror needs a channel |

The bot policy as a boolean circuit is counted by
`packages/engine/tool/circuit_count.dart` (doc 04); the bots' strength
by `packages/engine/tool/knobs.dart` and `tool/arena.dart`.
