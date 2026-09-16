# Measurements

Numbers the design rests on, each with the code that produced it and
the command that reproduces it. The docs quote them; this is where they
come from.

| | Question | Answer, in short |
|---|---|---|
| [`shuffle/`](shuffle/README.md) | What does a verifiable 52-card shuffle cost, native and in wasm? | doc 03: fast enough to deal every hand |
| [`sign/`](sign/README.md) | How long do BIP-340 signatures take in a browser? | 100 ms in Dart-to-JavaScript, 0.6 ms in wasm; the web app uses the wasm |
| [`channel/`](channel/README.md) | What does a WebRTC data channel carry, and what does carrying it cost the table? | doc 04: the channel is not the constraint; a hand affords about 700 bytes a gate, and bulk must not share the table's channel |
| [`ot/`](ot/README.md) | What does a gate cost before it is computed — the transfers, and the authenticated triple on top? | doc 04: 772 bytes and 191 µs in wasm a triple, half of it the check; 39.5 MB and ten seconds a hand, which is a p90 hand and not a p50 one — and five ranked ways to cut it, the largest being to make triples only for the hands that spend them |
| [`relay/`](relay/README.md) | What does the relay path carry — the only path a juror has? | doc 04: 1.79x sealed and signed, and 390 bytes a gate against the channel's 700; above that a juror needs a channel |

The bot policy as a boolean circuit is counted by
`packages/engine/tool/circuit_count.dart` (doc 04); the bots' strength
by `packages/engine/tool/knobs.dart` and `tool/arena.dart`.
