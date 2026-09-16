# What a gate costs before it is computed

[Doc 04](../../docs/04-live-play.md)'s computation spends one
**authenticated AND triple** per AND gate of the circuit a bot-held
seat costs — **53,726 of them a hand**
(`packages/engine/tool/circuit_count.dart`) — and every one of them is
made before the hand it is for. This measures the whole of that: the
oblivious transfers underneath, and the authentication on top that
turns them into a triple.

```bash
cd measurements/ot
cargo test --release                                    # it is the protocol it says it is
cargo run --release [transfers] [triples] [bucket]      # native, one core
cargo build --release --target wasm32-unknown-unknown
node bench.mjs [transfers] [triples] [bucket]           # the same code as wasm
```

**This is a benchmark, not a protocol.** Both parties run in one
process over shared memory, the base transfers are handed over rather
than performed, the equality and MAC checks that a real run batches at
the end are counted rather than performed, and none of it has been
reviewed to be used for anything. What it is for is the number. **The
times below are both parties' work; one party does about half.**

The protocol is Wang, Ranellucci and Katz, [*Authenticated Garbling and
Efficient Maliciously Secure Two-Party Computation*](https://eprint.iacr.org/2017/030)
(CCS 2017): Π_HaAND for the cross terms of a product, Π_LaAND for a
triple that is right but leaks a little, Π_aAND to bucket B leaky
triples into one that does not.

## The transfers

IKNP extends κ = 128 real public-key transfers into as many as you
like, each a few symmetric operations and κ bits on the wire, and the
KOS check makes that safe against a receiver that cheats.

A million transfers, this dev box's core, and the same wasm under
Node's V8 (the engine Chrome runs):

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
cipher calls and nothing else are thirteen and forty-four times slower
in wasm, because a core has an AES instruction and wasm has none.
Everything else is within a factor of two or three, and a phone's core
is several times slower again than this one.

**The check is the other half, and this implementation is the slow
one.** Its field multiplication is shift and xor over 128 bits; a core
with a carry-less multiply instruction does the same in a few
nanoseconds, which is why every table here gives the total both ways.
wasm has no carry-less multiply either, so a browser would need a
table-driven multiplication rather than this one — a real piece of work,
and [the biggest one on offer](#what-would-move-it).

## And the authentication on top

**An authenticated bit is free.** A correlated transfer hands the
receiver a row and the sender a row that differ by the sender's secret
exactly where the receiver's choice bit is set — which *is* the IT-MAC:
the choice is the bit, the receiver's row is the MAC, the sender's row
is the key, the sender's secret is the global key. So an aBit costs one
transfer and nothing else, and the triple's cost is counted in
transfers.

A leaky triple spends six of them, four bits for the cross terms and
the product, and three κ-bit strings each way for the check that it
really is an AND. Then B of those make one that does not leak.

Per triple, at the bucket of four a hand's batch calls for:

| | native | wasm |
|---|---|---|
| the transfers under them | 44.3–46.8 µs | 133.3 µs |
| the cross terms (Π_HaAND) | 0.58–0.60 µs | 9.7–9.8 µs |
| the leaky check (Π_LaAND) | 1.63–1.78 µs | 47.0–51.6 µs |
| bucketing (Π_aAND) | 0.34–0.42 µs | 1.1 µs |
| **all of it** | **46.8–51.3 µs** | **191–196 µs** |
| without the KOS check | 6.1–6.4 µs | 87–93 µs |
| **on the wire** | **772 bytes** | |
| | 24 transfers, 144 block cipher calls | |

**Half the wire is the bits and half is proving they multiply.** 384
bytes of transfers, 388 bytes of check — which is the answer to the
question this file was left open on. The transfers are the floor and
they are almost exactly half of it.

## What it comes to for a hand

53,726 triples, one a gate, at a bucket of four:

| | |
|---|---|
| on the wire | **39.5 MB**, 772 bytes a gate |
| CPU, native, both parties | 2.5–2.8 s (0.3 s with the check at hardware speed) |
| CPU, wasm, both parties | 10.3–10.5 s (4.7–5.0 s without the check) |

Against [the channel](../channel/README.md), which affords 698 bytes a
gate on 5 Mbit/s over a p50 hand of a minute and 1,396 over a p90 hand
of two: **it does not fit in a minute and does fit in two.** 39.5 MB is
66 seconds of a 5 Mbit/s uplink, and 13 seconds of a 25 Mbit/s one.

Against [the relay](../relay/README.md) — which is the only path a
juror has, and doc 04 makes the foreman a computing party at one human
— the same material is sealed and enveloped at 1.79x, so 74 MB and
**119 seconds**: a whole p90 hand, and nothing like a p50 one.

## What would move it

**A bigger batch buys a smaller bucket.** The bucket is four because a
hand is 53,726 triples, and the paper's Table 4 puts B = 4 from 3.1K
triples upward at ρ = 40 and B = 3 only past 280K. 280K is about six
hands. Preprocess a game's worth rather than a hand's and the bucket
drops to three — measured, by running the same code at `bucket = 3`:

| | bucket of 4 | bucket of 3 |
|---|---|---|
| on the wire | 772 bytes a gate | **579** |
| a hand | 39.5 MB | **29.7 MB** |
| CPU, wasm | 10.3 s | **7.9 s** |
| 5 Mbit/s, a hand's worth | 66 s | **50 s** |

Which crosses the line: 579 bytes a gate is inside the channel's p50
minute, where 772 is not. A game is several hands and the material is
per hand anyway, so the batch is there to be taken.

**A table-driven field multiplication buys the rest.** The KOS check is
104 of the 133 µs a triple's transfers take in wasm, and more than half
the whole. Without it a hand is 4.7 s instead of 10.3. That is the one
piece of arithmetic in here that a browser does badly for a reason that
can be fixed, and it is worth doing before anything else.

## What the tests are for

The numbers mean nothing if the protocol is not the protocol, so:

- the sender's row and the receiver's row differ by the sender's secret
  exactly where the choice bit is set — the relation the extension
  rests on, and the reason an aBit is free;
- the bit transpose puts every bit where it belongs;
- the field the check multiplies in is associative and distributive,
  which is what a wrong reduction breaks;
- every transfer leaves an authenticated bit: `mac = key ⊕ v·Δ`, on all
  of them;
- every leaky triple is an AND, its z is authenticated, its check
  holds — over enough of them that each of the four cases of the two
  parties' shares of x, which take different branches, is taken many
  times;
- **a wrong product fails the check**, which is the test that says the
  cases were transcribed the right way round: a check that always
  passed would satisfy every other test here;
- a bucket of leaky triples is still a triple;
- and the wire is exactly what the protocol puts on it, counted step by
  step against the figures above.

### One correction to the paper

Figure 8 step 3 prints `u = v1 ⊕ x1y1`, which would make PB's share the
whole product on its own and leave `[z1]` — which step 1 draws and step
4 checks against — doing nothing. Working the four cases of the two
parties' shares of x through T and V shows the check holds exactly when
`z1 ⊕ z2 = x ∧ y`, which is also what F_aAND in Figure 7 asks for, so
the term is `u = v1 ⊕ x1y1 ⊕ z1`. That is what is implemented here, and
the tests above are what say so.
