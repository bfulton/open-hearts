# 03 — A deal nobody can rig

**Question.** With no server, how do four strangers agree that the cards
were shuffled fairly and that nobody can see anyone else's hand?

**Answer.** This is a solved problem with a name: **mental poker**. The
short version is that you do not need to elect anyone to trust. A trusted
dealer is exactly the thing the protocol removes.

## Why the obvious answer is not enough

The instinct is commit-and-reveal on a shuffle seed: every player commits
to `H(rᵢ)`, everyone reveals `rᵢ`, and the deck is shuffled from
`seed = H(r₁‖r₂‖r₃‖r₄)`. Nobody controls the seed unless everybody
colludes, and it is a dozen lines of code.

It is genuinely useful — and it solves the wrong half. Once the seed is
public, *the whole deal is public*: anyone can run the same shuffle and
read all four hands. It stops a stacked deck and provides no secrecy at
all, and in Hearts the hidden hand is the game.

Rotating a designated dealer does not fix it either. Whoever deals sees
everything, and rotating merely spreads the privilege around.

So the requirement is both properties at once: a shuffle no single player
controls, **and** a deal where each player learns exactly their own
thirteen cards and nothing else.

## What mental poker gives you

The modern construction is **Barnett–Smart** (*Mental Poker Revisited*,
2003), which refined the original idea of Shamir, Rivest and Adleman
(1979) into something efficient enough to run for real. It is built from
parts that are all standard:

**Setup.** Each player picks a secret `xᵢ` and publishes `hᵢ = g^{xᵢ}`.
The table's shared ElGamal key is `h = h₁h₂h₃h₄`. A card encrypted under
`h` can only be opened with help from **every** player — so any one
honest player is enough to keep a card secret.

**Shuffle.** The 52 cards are fixed group elements. Each player in turn
takes the deck, re-randomizes every ciphertext, applies a **secret**
permutation, and publishes a zero-knowledge **proof of correct shuffle**
— a proof that the output is a permutation and re-encryption of the
input, revealing nothing about which. The other three verify it. After
four shuffles the deck is uniformly random unless all four collude, and
nobody knows the order.

**Deal.** To give a card to player *i*, the other three each publish a
partial decryption share with a Chaum–Pedersen proof that the share was
computed with the same secret key they committed to at setup. Player *i*
divides out those three shares, applies their own, and reads the card.
The other three learn nothing — they contributed to opening a card they
cannot see.

**Reveal.** Playing a card to a trick is just the holder publishing their
own share plus a proof. Because the ciphertext binds the card, a player
cannot claim to hold something they do not.

**Audit.** At the end of a hand everyone reveals `xᵢ` and the entire deal
can be replayed and checked by anyone.

The proof of correct shuffle is the only exotic part, and it is well
covered: **Neff** (2001) is `O(n)` and simple; **Bayer–Groth** (2012) has
smaller proofs and matters at deck sizes far beyond 52. There are Rust
implementations of Barnett–Smart built on `arkworks`, which matters here
because `countmein` already ships a Rust crate compiled to `wasm32` and
called from Flutter web — the same road, already paved.

## Will it run on a phone?

The number that decides this is how the cost is distributed, and it falls
the right way: **the crypto is per-hand, not per-play.**

| Step | Rough work | When |
|---|---|---|
| Four shuffles + four proofs | a few thousand scalar multiplications | once per hand |
| Deal 52 cards, 3 shares each | a few hundred scalar multiplications | once per hand |
| Play one card | one share + one small proof | per play |
| Verify one play | a handful of multiplications | per play |

On a mid-range phone in WASM a scalar multiplication on a modern curve
(ristretto255 or similar) is tens of microseconds. That puts a full
verifiable deal in the neighbourhood of a few hundred milliseconds of
compute, spread over about eight messages between players — call it one
to two seconds of "dealing…" at the start of a hand, which is roughly how
long dealing takes at a real table anyway.

Playing a card stays in the noise. **Sub-second play and a provably fair
deal are not in tension**, because they are not the same cost.

These are estimates from published complexities, not measurements. The
first task in this line of work is a benchmark, not an implementation:
build the shuffle-and-prove step for n=52, run it in wasm on an actual
phone, and put the real number here. If it comes back at ten seconds
instead of one, the design changes and it is much cheaper to learn that
before anything is built on top of it.

## What it still does not stop

Worth stating plainly, because cryptography invites over-claiming:

- **Collusion.** Two players sharing hands over a phone call defeat every
  protocol in this document. Nothing here helps.
- **A player running a solver.** Same.
- **Rage-quitting.** A liveness problem: timeouts and an abandonment
  rule, not crypto.

What it does stop is the entire class of cheating that a serverless game
would otherwise be wide open to: a stacked deck, a peeked hand, a card
claimed but never held.

## The plan

1. Ship local play. **Done.**
2. Real players over WebRTC with the shared rules engine as referee
   ([doc 02](02-multiplayer.md)). Good enough for friends, and friends
   are not the threat model.
3. Benchmark a 52-card verifiable shuffle in wasm on a real phone.
   Publish the number.
4. If the number holds, implement Barnett–Smart and make the fair deal
   the default for tables with strangers.

Steps 2 and 3 are independent and can run in either order.
