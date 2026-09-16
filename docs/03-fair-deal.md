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
because a Rust crate compiled to `wasm32` and called from Flutter web is
a well-worn path — the shuffle would not be the thing breaking new
ground.

## Will it run on a phone?

The number that decides this is how the cost is distributed, and it falls
the right way: **the crypto is per-hand, not per-play.**

| Step | Rough work | When |
|---|---|---|
| Four shuffles + four proofs | a few thousand scalar multiplications | once per hand |
| Deal 52 cards, 3 shares each | a few hundred scalar multiplications | once per hand |
| Play one card | one share + one small proof | per play |
| Verify one play | a handful of multiplications | per play |

**Measured, not estimated.** [`measurements/shuffle/`](../measurements/README.md)
times the reference implementation of exactly this protocol —
Barnett–Smart with a Bayer–Groth shuffle argument, from
geometryxyz/mental-poker, on the Starknet curve — through one deal: four
shuffle-and-remask proofs, their verification, and one seat opening its
thirteen cards.

| Step | native, x86-64 | wasm, Chromium 141, same core |
|---|---|---|
| shuffle + prove, one player | 80 ms | 370 ms |
| verify one shuffle proof | 36 ms | 163 ms |
| one reveal token with its proof | 0.4 ms | 1.6 ms |
| unmask one card, four tokens' proofs checked | 2.2 ms | 8.8 ms |
| **critical path, sit to cards in hand** | **0.47 s** | **2.1 s** |

The critical path is the four shuffles one after another, each verified
before the next begins, then the tokens and the opening; network time is
not in it. Any one player's own compute is about half of it.

Two things about those numbers. They are for the reference crate as
found — generic field arithmetic, no wasm SIMD, a curve picked for a
different purpose — and a tuned implementation on ristretto255 is
usually several times faster. And they come from a desktop-class core;
a phone is two to three times slower. So **expect four to six seconds of
"dealing…" on a phone with this crate as it stands**: more than the one
to two seconds this section once estimated, well short of the ten that
would send the design back. The conclusion is implement the deal, then
optimise it — not redesign it.

The phone's own number is one tap away: `deploy.sh` publishes the same
benchmark at `/measure/shuffle/` on the dev site whenever the wasm has
been built, and that number belongs in the table above.

Playing a card stays in the noise — a token and a proof, two
milliseconds. **Sub-second play and a provably fair deal are not in
tension**, because they are not the same cost.

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

## Exactly what is guaranteed

Worth stating precisely, because this is the claim the whole product
rests on and an overstatement would be found and quoted.

- **The deal cannot be rigged.** All four players shuffle in sequence
  with proofs, and one honest shuffler is enough — so this holds even at
  a table of one human and three bots, which is exactly when a player
  would most suspect otherwise.
- **Nobody can see your cards.** Not another player, not us, and not
  whoever is left at the table after you go. Any coalition able to open
  a hand contains every human at the table plus a randomly drawn
  stranger who has no stake in it — [doc 04](04-live-play.md) has the
  construction.
- **Nobody can misrepresent a card**, because the ciphertext binds it.
- **Every game verifies end to end** against the committed deal, by
  anyone, after the fact.

No exceptions. Earlier drafts of this document carried one — a player
left alone with three bots could see them — and the jury in doc 04 is
what removed it.

## Has anyone actually built this?

Yes — and notably, **including a trick-taking game**, which is the part
that was not obvious.

**SecureSkat** is a peer-to-peer implementation of Skat, the German
three-handed trick-taking game, built on **LibTMCG** (Heiko Stamer's C++
library implementing Schindelhauer's toolbox). Wikipedia's article on
mental poker calls LibTMCG the first practical implementation of these
protocols, and describes SecureSkat as achieving "modest real-world
performance." That matters more than any poker implementation does,
because Skat and Hearts are the same shape of problem: a full deal to
every player, hidden hands, tricks. LibTMCG's own description lists
hearts among the games its protocols suit — nobody has built it.

Everything modern is poker. The most relevant:

| | |
|---|---|
| [geometryxyz/mental-poker](https://github.com/geometryxyz/mental-poker) | Rust, Barnett–Smart with the Bayer–Groth shuffle argument. Needs only an elliptic curve — no pairing-friendliness, no high 2-adicity. Research-origin, unaudited. The closest thing to a reference implementation of the protocol above |
| [predatorray/mental-texas-holdem](https://github.com/predatorray/mental-texas-holdem) | Browser P2P over WebRTC, no server. Architecturally the closest to what we would ship, even though the game is wrong |
| [vladris/mental-poker-toolkit](https://github.com/vladris/mental-poker-toolkit), [monicanagent/cypherpoker](https://github.com/monicanagent/cypherpoker), [kripod/mental-poker](https://github.com/kripod/mental-poker) | Other toolkits, various protocols and maturity |
| [dpinones/mental-poker](https://github.com/dpinones/mental-poker) | ZK proofs in the browser (Noir), verified on-chain |

So the position is: the protocol is settled, a trick-taking game has been
done before, a Rust implementation of the exact construction exists, and
browser P2P poker without a server ships today. **No part of this is
unproven.** What is missing is that nobody has put them together for
Hearts.

## As built

The deal is built — `crypto/deal` and `crypto/vendor`, `packages/deal`,
and "the deal" section of `packages/table/lib/src/client.dart` — and
every live table is sealed: the room's start event and the matchmaking
offer say so, and a build that cannot run the deal does not sit down.

- **The primitives** are the reference crate measured above —
  Barnett–Smart with the Bayer–Groth argument on the Starknet curve,
  m = 2 and n = 26 — wrapped as flat functions over bytes: keys and
  their proof of ownership, the joint key, the initial deck, a shuffle
  with its argument, reveal tokens with their proofs, unmasking, and
  sealing a token to one key. One Rust crate builds twice: a cdylib
  the Dart VM loads over FFI (the tests, the verifier, the service's
  juror) and a 400 KB wasm the browser loads bare, no glue. Every
  random value comes in as a seed the caller drew; the wasm has no
  entropy source and refuses to pretend it has one. Two of the
  reference's proof crates are vendored for one fix: a point written
  into a proof's transcript is normalised first, because a proof made
  from Jacobian coordinates and verified from its bytes hashed two
  different things, and every proof here crosses a wire.
- **A hand's deal is turns of the table** ([doc 04](04-live-play.md)).
  Four rounds of one turn per seat before the pass — keys, a shuffle
  in seat order, reveal tokens for the other seats' thirty-nine
  positions, and the lead card declared by its holder with the token
  that opens it for everyone — and four audit turns after the last
  trick, each person's deal secret for all, so the hand replays. Each
  is a race like any other turn: the seat wins it by acting, checked
  by everyone on arrival, or loses it by removal. A bot's step is
  public work everyone computes, from a secret that is a hash of what
  everyone knows.
- **A pass** moves positions, for all to see, with the tokens that
  open them sealed to the receiver (ElGamal under its deal key, the
  reveal proof in the clear beside it) — or in the clear outright when
  the receiver is a bot. Each seal carries an argument that what is
  inside it is the share the passer's key owes for that card, which
  every seat checks without being able to look ("A sealed token, and
  the argument that it is the right one", below). **A play** is the token that
  opens its position for everyone; the card it names must be the card
  that opens, and it is legal as far as the rules can tell without the
  hand — the first trick is led with the 2♣ — with the rest checked at
  the audit.
- **Escrow.** With its keys, each person splits its deal secret into
  two pieces: one to every other person at the table, one to every
  juror of the hand ([doc 04](04-live-play.md)), each copy wrapped in
  a secret the two table keys share — Diffie–Hellman on the curve the
  keys already live on. Any one person and any one juror rebuild a
  departed seat's secret once the table has removed it; all the people
  together hold noise without a juror's piece, and the jury noise
  without a person's — doc 04's bound. Whoever holds a piece releases
  it when the seat goes, and again every few seconds until the secret
  is known; the seat's turns stall meanwhile, and the rail says so. A
  hand's audit waits the same way for a seat removed at it. The price
  of the bound: with the whole jury of a hand gone — every juror it
  was drawn with crashed — a seat that leaves it can no longer be
  opened, and the table pauses for the rest of the hand and says so;
  the chaos walk reaches that state only by crashing four jurors.

  **The pieces are of the secret, and rebuilding it opens the whole
  hand** to whoever rebuilt it — which is the thing
  [doc 04](04-live-play.md)'s computation is written to avoid. The
  cryptography for the other way is built and tested in `crypto/deal`,
  and the escrow has yet to move onto it:

  - `split` divides the **key**, in the field it lives in, into as many
    shares as a table needs; `shareKey` gives each share's public key,
    and they add to the seat's own, which is what says a split is a
    split of *that* key.
  - `shareToken` is one share's part of opening a card, proved against
    its own share key. Nothing combines them: unmasking adds every
    token it is given, so a seat's shares go in as tokens beside the
    other seats' and the card comes out with the key never anywhere.
  - `openShared` does the same for a **seal**. A pass to a seat that
    then leaves is a ciphertext only that seat's key opens, and a seal
    is a ciphertext of a card's shape, so a share's part of opening one
    is a token made over the seal itself.

  What that would buy is that a holder releases what a position needs
  rather than the key that opens everything — so when the bot plays
  inside the computation it is one position a turn, and the rest of the
  hand stays shut until the audit opens every hand anyway. Against a
  colluding person and juror it changes nothing, and the bound above
  already says so; what it changes is that honest survivors no longer
  learn a departed hand in order to play it.

  **Two things a first attempt at moving the escrow over turned up**,
  written down so the next one starts with them. A seat that leaves
  *before the deck is dealt* still owes a shuffle, and a shuffle is a
  computation with the secret rather than a decryption with the key, so
  the secret's pieces cannot simply be replaced — the two escrows have
  different lifetimes and both are needed. And the shares have to reach
  the peers that do not hold them: a person holds the people's share
  and a juror the jury's, so each can make its own part of opening a
  seal but needs the other's, and a release that goes out before a peer
  has seen the pass it covers carries nothing for it.

  **The design those two findings give**, which is what the next
  attempt builds. The first says the share escrow does not replace the
  secret escrow; it sits beside it and covers a different window. Both
  are made at the keys message: the secret in two pieces as now, and
  the key in two shares, the people's and the jury's, wrapped to the
  same table keys and costing the same 32 bytes each. The shares' keys
  ride along in the open, and a keys message is refused unless they add
  to the seat's own — which is what says the shares are shares of *that*
  key, and it is checked by everyone, not only by a holder.

  Then the window decides which escrow answers:

  - **Before the deck is dealt**, a departed seat still owes a shuffle,
    so the secret pieces are released and the secret rebuilt, exactly
    as today. Nothing is gained by shares here and the shuffle cannot
    be done without the secret.
  - **In play**, nothing releases a share. A holder releases *share
    tokens*: for each position still missing the seat's token, a
    `shareToken` over that position, proved against that holder's share
    key. Two such sets — a person's and a juror's — join the three
    living seats' tokens, and unmasking over five keys opens the card.
    The survivors learn the positions they open and nothing else, and
    the departed key is never anywhere. This is the window the
    confidentiality is for.
  - **At the audit**, the hand is opened to everyone anyway, so the
    secret pieces are released and the secret rebuilt. The audit, and
    the verifier that replays it, are unchanged.

  The second finding is why the release is of tokens and not of shares.
  A share that crossed would hand the other side the power to open
  every position, which is the whole thing being avoided; a token
  crosses for one position and says nothing about the next. It also
  answers the crossing problem directly, because a token is made
  against a position both sides can already see in the dealt deck,
  rather than against a pass one side may not have heard yet. A release
  covers *every position the seat's token is missing from*, so a seat
  that left before sending its tokens is covered by the same message as
  one that left after.

  The cost is a release of thirteen tokens where there was one 32-byte
  piece — some 1.7 KB against the 49,143 bytes of payload a sealed
  event carries ([the relay measurements](../measurements/relay/README.md))
  — and at worst fifty-two, for a seat that left before its tokens went
  out.

- **The interim.** Until the bot plays inside the computation
  ([doc 04](04-live-play.md), "Playing a seat nobody holds"), a bot's
  hand is open to everyone at the table, and so is a departed person's
  once the escrow opens it. So at a table of two people and two bots,
  each person sees their own cards and the bots', never the other
  person's; at four, nobody sees anyone's. The shuffle's guarantee
  holds regardless: one honest shuffler is enough.
- **The verifier** replays a sealed record through the deal: every
  key's proof, every shuffle's argument against the deck before it,
  every token, the lead card's declaration; then the audit's secrets
  open every card, each play's token must open the card it named, and
  every play is checked against the hand it came from as fully as a
  seeded game's. Until a hand's audit is in, its plays are checked as
  far as the rules allow and the verification says it is not complete.
- **Measured here**, the reference crate on this machine's core,
  native: a shuffle with its argument 110 ms, verifying one 108 ms, a
  token 1.1 ms to make and 2.3 ms to check, a sealed token with its
  argument 2.1 ms to make and 3.5 ms to check, a card 7.5 ms to open
  when its four proofs are checked again — which is why each token is
  checked once, on arrival, and the cards are opened without. A
  four-person hand costs each seat about a second of its own work, a
  juror following the table the same. What the deal exposed was not
  its own cost but the signatures around it: a juror summoned mid-hand
  is carried forward through every event of the hand, and at seventeen
  milliseconds a signature in pure Dart the service's relay and juror
  drowned in the catch-up. `crypto/schnorr` is the browser's signature
  wasm built for the VM, two hundred times faster, and an event seen
  before is taken by its id without a second check.

### A sealed token, and the argument that it is the right one

A pass seals the three tokens to the receiver, and that used to be the
end of what anybody could say about them. What is sealed is for one
seat's eyes, so no third party could tell an honest seal from three
cards the receiver would never open — and a receiver left unable to play
three of its own cards had no way of saying so that anyone could check.

So each seal carries an argument. The passer knows two secrets: its deal
secret `sk`, and the randomness `r` it sealed with. Those satisfy three
relations at once, over the ElGamal generator `G`, the masked card's
first half `C1`, and the receiver's key `pk_to`:

```text
    pk = sk·G                    the passer's own key, already public
    c1 = r·G                     the seal's first half
    c2 = sk·C1 + r·pk_to         its second: the token sk·C1, blinded
```

and `sk·C1` is exactly the reveal token the passer owes for that card.
One Σ-protocol over the two witnesses proves knowledge of them — commit
with a random pair, take the challenge from a hash of the whole
statement, answer with `z1 = a + c·sk` and `z2 = b + c·r` — and it says
nothing at all about the token itself. **160 bytes, and every seat
checks it before it takes the pass.** A pass that fails it is not a
pass: it never settles, its seat is left at its own turn with nothing
carried, and the clock takes the seat there like any other turn that
will not come. The receiver is never the one who suffers, and never has
to complain.

**One fault is left that no proof can catch.** A seat that holds the 2♣
can say it holds it nowhere: there is nothing to prove about a card you
say you do not hold, and no argument can be asked for. Then every seat
has said "not me", one of the four thirteens has it, nobody can lead,
and no seat's word will say which lied. What the table does is open the
hand where it stands — the audit called at the top of it instead of at
the end — and then give it up: nothing scored, and the next hand dealt
in its place without the seat the opened deal names. A hand given up is
the redeal, in everything but its number: a hand's turns live under its
own number, so the fresh deal is the next hand rather than the same one
again.

The seat that lied is removed at the first turn of its own that opens in
the hand after — never at the turn it lied at, which settled long before
the cards said so. A client that will not answer that audit is booted at
the turn it will not answer. One that plays on by itself, alone in
knowing who leads, is a client whose heartbeats stop moving, and a peer
that has not moved for longer than a decision may take is not catching
up.

**A verifier sees it for itself**, which is why the hand is opened
before it is given up: with every secret in, a hand given up must show a
seat that was dealt the lead card and disclaimed it. That is not a thing
a majority can arrange — only that seat could have — so a table cannot
throw away a hand it merely dislikes.

**Tests.** `packages/deal`: every primitive round trips, and four
sessions in one process deal, pass, play, lose a seat and rebuild it,
and audit, with a verifier that saw only the messages.
`packages/table/test/sealed_test.dart`: whole sealed games at one, two
and four people that verify to the end; a person leaving mid-hand and
during the deal; a table of two surviving a crash on turn by the
jury's verdict and a juror's piece; and both faults committed for real
— every seat disclaiming the two of clubs, by a client that deals
itself the hand anyway and by one that waits with the rest, and a pass
sealed to nothing — each played out to a game that finishes and
verifies. The jury over real sockets
(`service/test`) runs sealed as well as seeded; the app's widget test
plays a sealed hand from seat 2; and the browser suite's four headless
browsers deal every hand this way.

## References

- Shamir, Rivest and Adleman, *Mental Poker*, MIT Technical Memo
  LCS/TM-125, 1979 — where the problem starts.
- Goldwasser and Micali, [*Probabilistic encryption & how to play mental
  poker keeping secret all partial
  information*](https://dl.acm.org/doi/10.1145/800070.802212), STOC 1982
  — the original leaked partial information; this closed it.
- Schindelhauer, *A Toolbox for Mental Card Games*, University of
  Lübeck, 1998 — general card operations rather than poker-specific
  ones. What LibTMCG implements.
- **Barnett and Smart, [*Mental Poker
  Revisited*](https://doi.org/10.1007/978-3-540-40974-8_29),
  Cryptography and Coding 2003, LNCS 2898, pp. 370–383 — the protocol
  this document describes.** Its contribution is that the bits per card
  no longer grow with the number of players.
- Bayer and Groth, [*Efficient Zero-Knowledge Argument for Correctness
  of a Shuffle*](https://doi.org/10.1007/978-3-642-29011-4_17),
  EUROCRYPT 2012 — the shuffle proof, with sub-linear communication.
- Neff, *A Verifiable Secret Shuffle and its Application to E-Voting*,
  CCS 2001 — the earlier shuffle argument; simpler, linear.

The shuffle proof arrives here from electronic voting, which wanted the
same guarantee for the same reason: prove a list was permuted without
revealing the permutation.

## The plan

1. Ship local play. **Done.**
2. Real players over WebRTC with the shared rules engine as referee
   ([doc 02](02-multiplayer.md)). Good enough for friends, and friends
   are not the threat model.
3. Benchmark a 52-card verifiable shuffle in wasm. **Done on a desktop
   core** (above); the phone's number is a tap away on the dev site.
4. If the number holds, implement Barnett–Smart and make the fair deal
   the default for tables with strangers. **Built** ("As built",
   above), for every live table, down to the argument that a sealed
   token is the right one: a hand no modified client can leave
   unfinished, and no fault it can commit and keep its seat. What
   remains is the bot inside the computation
   ([doc 04](04-live-play.md)).
