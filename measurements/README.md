# Measurements

Numbers the design rests on, each with the code that produced it and
the command that reproduces it. The docs quote them; this is where they
come from.

| | Question | Answer, in short |
|---|---|---|
| [`shuffle/`](shuffle/README.md) | What does a verifiable 52-card shuffle cost, native and in wasm? | doc 03: fast enough to deal every hand |
| [`sign/`](sign/README.md) | How long do BIP-340 signatures take in a browser? | 100 ms in Dart-to-JavaScript, 0.6 ms in wasm; the web app uses the wasm |

The bot policy as a boolean circuit is counted by
`packages/engine/tool/circuit_count.dart` (doc 04); the bots' strength
by `packages/engine/tool/knobs.dart` and `tool/arena.dart`.
