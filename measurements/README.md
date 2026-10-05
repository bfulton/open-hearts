# Measurements

Numbers the design depends on, each with the code that produced it.

| | Question | Answer |
|---|---|---|
| [`shuffle/`](shuffle/README.md) | What does a verifiable 52-card shuffle cost, native and in wasm? | Fast enough to deal every hand ([doc 03](../docs/03-fair-deal.md)) |
| [`sign/`](sign/README.md) | How long do BIP-340 signatures take in a browser? | 100 ms in Dart compiled to JavaScript, 0.6 ms in wasm; the web app uses the wasm |

The bots' strength is measured by `packages/engine/tool/knobs.dart` and
`tool/arena.dart`.
