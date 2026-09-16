# What an oblivious transfer costs

[Doc 04](../../docs/04-live-play.md)'s computation needs one
authenticated AND triple per AND gate of the circuit a bot-held seat
costs — **53,726 of them a hand**
(`packages/engine/tool/circuit_count.dart`) — and a triple is built from
oblivious transfers. The transfers are nearly free after a fixed start:
IKNP extends κ = 128 real public-key transfers into as many as you like,
each costing a few symmetric operations and κ bits on the wire, and the
KOS check makes that safe against a receiver that cheats. This measures
the per-transfer cost, which is the one that multiplies.

```bash
cd measurements/ot
cargo test --release                                    # it is the protocol it says it is
cargo run --release                                     # native, one core
cargo build --release --target wasm32-unknown-unknown
node bench.mjs                                          # the same code as wasm
```

**This is a benchmark, not a protocol.** Both sides run in one process
over shared memory, the base transfers are handed over rather than
performed, and none of it has been reviewed to be used for anything.
What it is for is the number. The base transfers it skips are κ
public-key operations once per pair, which against tens of thousands of
extended ones is noise.

The tests are what make the numbers mean anything: that the sender's row
and the receiver's row differ by the sender's secret exactly where the
receiver's choice bit is set — the relation the whole extension rests on
— that the bit transpose puts every bit where it belongs, and that the
field the check multiplies in is associative and distributive, which is
what a wrong reduction breaks.

A million transfers, this dev box's core, and the same wasm under Node's
V8 (the engine Chrome runs):

| | native | wasm | |
|---|---|---|---|
| expand the seeds (AES-CTR) | 93 ns | 1,211 ns | 13× |
| transpose the bit matrix | 81 ns | 92 ns | 1.1× |
| the KOS check (GF(2^128)) | 1,850 ns | 4,338 ns | 2.3× |
| hash each row (fixed-key AES) | 26 ns | 1,156 ns | 44× |
| **all of it, per transfer** | **2,050 ns** | **6,797 ns** | 3.3× |
| without the check | 200 ns | 2,459 ns | 12× |
| **on the wire, per transfer** | **16 bytes** | | |

**What the browser pays for is AES.** The two phases that are block
cipher calls and nothing else — expanding the seeds and hashing the rows
— are thirteen and forty-four times slower in wasm, because a core has
an AES instruction and wasm has none. Everything else is within a
factor of two or three. Anything built here should expect that, and a
phone's core is several times slower again than this one.

**The check is the other half, and this implementation is the slow
one.** Its field multiplication is shift and xor over 128 bits; a core
with a carry-less multiply instruction does the same in a few
nanoseconds, which is why the table gives the total both ways. wasm has
no carry-less multiply either, so a browser would need a table-driven
multiplication rather than this one — that is a real piece of work and
worth knowing about before it is started.

## What it comes to for a hand

At one transfer a gate, a bot-held seat for one hand:

| | |
|---|---|
| on the wire | 839 KB |
| CPU, native | 110 ms (11 ms with the check at hardware speed) |
| CPU, wasm | 365 ms (132 ms without the check) |

Against the budget the channel measurement gives —
[about 700 bytes a gate](../channel/README.md), 37 MB over a minute on
5 Mbit/s — **839 KB is not close to the limit.** A triple costs more
than one transfer, so multiply: even at twenty transfers a gate it is
17 MB and about seven seconds of a browser's CPU a hand, which is inside
a minute and inside the link, and a phone at three times slower is still
inside it.

So neither the transfers nor the wire is what would stop this. What the
two measurements together say is that the constraint is **the shape of
the traffic, not its size**: 17 MB handed to the stack in one go is
thirteen seconds of head-of-line blocking on a 5 Mbit/s link
([channel](../channel/README.md)), and the seat that did it would be
booted for silence while its own upload drained. Paced, on a channel of
its own, a hand's worth of preprocessing fits.

What is still unmeasured is the rest of a triple — the transfers are the
floor, and the authentication on top of them is what a real
implementation would have to be timed for.
