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

Five things, in the order they are worth taking. The first two are
measured here; the third is a scheduling decision; the last two are
the literature, quoted from the papers.

**1. Build the circuit when its turn comes.** The gate count is a
multiplier on everything, and 53,726 is the circuit built before the
hand: legality, the trick, what has been played, whether hearts are
broken and which of the thirteen dealt positions are still in hand all
carried as secret inputs. Every one of those is *public* by the time
the card is chosen, and a public input folded in is a constant that
costs nothing (`packages/engine/tool/circuit_count.dart`):

| | before the hand | at its turn |
|---|---|---|
| one play over positions | 3,316 | 1,571–2,591, median 2,113 |
| one pass | 10,618 | 10,618 |
| **a bot-held seat's hand** | **53,726** | **44,301 at worst, 38,136 on average** |

**29% off the average hand, and nothing given up** — the preprocessing
is function-independent, so it does not care what circuit the triples
end up in, and a play that needs fewer than the worst case leaves the
rest for the next one. The cost is that the garbling has to happen at
the turn rather than ahead of it. The pass does not move, because at
pass time there is no table state yet to fold, and it is now a quarter
of the hand.

**2. A bigger batch buys a smaller bucket.** The bucket is what the
leak costs, and it falls as the batch grows — the paper's Table 4 at
ρ = 40, and every row measured here by running the same code at that
bucket:

| bucket | needs a batch of | on the wire | a 38,136-gate hand |
|---|---|---|---|
| 6 | — | 1,158 bytes a gate | 42.1 MB |
| 5 | 320 | 965 | 35.1 MB |
| **4** | **3.1K** | **772** | **28.1 MB** |
| 3 | 280K | 579 | 21.1 MB |

A hand is 38K triples, so four. Six or seven hands is 280K, so a whole
game's worth in one batch is three — a quarter off, for committing to
the whole game up front.

**3. Only make the triples a bot actually spends.** Which is the big
one, and it is not cryptography. A triple is function-independent and
fungible: a hand needs them only if one of its seats is being played by
a bot, and most hands have nobody leave. Preprocessing a hand a hop
ahead spends 28 MB every hand against the chance of a departure;
preprocessing two plays at a time spends 1.9 MB a play, only for plays
a bot really makes, and keeps the bucket at four because two plays is
5.2K triples. **A standing buffer of 3.8 MB in place of 28 MB a hand.**

What it costs is the first play after a surprise departure, which has
to make its triples on the spot: 3.8 MB is six seconds on 5 Mbit/s,
inside a decision's six-second grace and well inside the seat's
45-second bank (`packages/table/lib/src/time_bank.dart`). After that
the buffer refills while the other three seats play. The pass is the
exception and does not need to be one — a seat that is bot-held at
pass time was bot-held before the hand began, so its 10,618 triples
have a whole hand of warning.

**Where it stops working is several bot seats at once**: a bot plays
instantly, so a hand with three of them runs at no human pace at all,
and three seats' triples would be wanted in seconds. That is the corner
to design for, and the honest answer there may be to let the table
wait.

**4. A newer protocol, for about a third off.** Katz, Ranellucci,
Rosulek and Wang, [*Optimizing Authenticated Garbling for Faster
Secure Two-Party Computation*](https://eprint.iacr.org/2018/578)
(CRYPTO 2018), computes the leaky triple and its check in one step
rather than two and takes the bucket size down by one. Their Table 2
puts the function-independent phase for AES at 3.8 MB against WRK17's
5.7. Their formula is `(4B − 2)κ + (3B − 1)ρ` a gate one way, and a
hand's batch needs four here so three there: 1,600 bits one way,
**400 bytes a gate** both ways, against the 772 measured here.

**5. A newer extension, which trades wire for CPU.** Half the wire is
the transfers, at IKNP's λ bits each. Roy's
[SoftSpokenOT](https://eprint.iacr.org/2022/192) (CRYPTO 2022) sends
λ/k bits instead, for 2^k/k times the computation, and reports a 5×
cut in practice — which would take the transfers from 384 bytes a gate
to about 77, and the hand from 28 MB to 17. But the computation it
adds is the seed expansion, which is the AES a browser is already
worst at: 2^k/k is 6.4× at k = 5, taking that phase from 29 µs a
triple to 186 and the whole triple from 191 µs to about 350 — a hand
of nineteen seconds of wasm rather than ten. On a phone that is the
wrong way round. Silent OT — communication logarithmic in
the number of transfers — is the same trade taken further.

**And the one that is not about size.** The KOS check is more than half
the browser's time: 104 of the 133 µs a triple's transfers take in
wasm, and without it a hand is 4.7 s instead of 10.3. A table-driven
GF(2^128) multiplication is the one piece of arithmetic in here that a
browser does badly for a reason that can be fixed.

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
