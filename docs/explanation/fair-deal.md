# The fair deal

Four strangers need to agree that the cards were shuffled fairly, and
each of them needs to see only their own hand. A shared seed does not
do this. If everyone commits to a random value and the deck is shuffled
from the hash of all of them, nobody controls the order, but once the
seed is public every hand is public too. A rotating dealer sees
everything. The requirement is both at once: a shuffle no single player
controls, and a deal where each player learns their own thirteen cards
and nothing else.

That is **mental poker**, and every live table uses it. Solo games have
nobody to prove anything to and use a seeded shuffle instead
([below](#solo-games-where-the-randomness-comes-from)).

## The protocol

Barnett–Smart (*Mental Poker Revisited*, 2003) with the Bayer–Groth
shuffle argument (2012). The implementation is the reference crate
[geometryxyz/mental-poker](https://github.com/geometryxyz/mental-poker)
on the Starknet curve, with the deck folded m = 4 by n = 13. It is wrapped as flat
functions over bytes in `crypto/deal`.

- **Keys.** Each seat draws a secret `xᵢ`, publishes `hᵢ = xᵢ·G` with a
  proof that it owns it, and the table's joint key is the sum. A card
  masked under the joint key opens only with a token from every seat,
  so one honest seat is enough to keep a card shut.
- **Shuffle.** The 52 cards start as fixed points. Each seat in turn
  remasks every card, applies a secret permutation, and publishes a
  Bayer–Groth argument that its output is a permutation and remasking of
  its input. Everyone checks each shuffle before the next one starts.
  With four shuffles the order is uniform unless all four seats collude.
- **Tokens.** Each seat publishes reveal tokens for the 39 positions
  dealt to the other seats. A token is `xᵢ·C1` for the card's first
  half. A seat combines the other three seats' tokens with its own to
  read its hand, and nobody else learns anything.
- **Declaring the lead.** The holder of the 2♣ declares it with the
  token that opens it for everyone.
- **Pass.** Moving three positions to another seat is public. The tokens
  that open them are sealed to the receiver (below).
- **Play.** A play is the token that opens a position for everyone, or,
  for a card that was passed, the receiver's opening of its seal. The
  card it opens must be the card named, so nobody can play a card they
  do not hold. The rules are checked as far as they can be without the
  hand, and the rest is checked at the audit.
- **Audit.** After the last trick every seat publishes its deal secret.
  Every card then opens, and every play is checked against the hand it
  came from.

All of this runs as turns of the table protocol
([live play](live-play.md), [table states](table-states.md)): four rounds before
the pass (keys, shuffle in seat order, tokens, lead declared) and the
audit after the last trick. Every step is checked by every side as the
log carries it. A seat whose clock runs out at a step of the deal is
given to a bot, as at any other turn.

One Rust crate builds twice. It builds as a cdylib that the Dart VM
loads over FFI (tests, the verifier, the house), and as a
wasm that the browser loads with no glue code (`app/web/deal.wasm`).
Every random value comes in as a seed from the caller. The wasm has no
entropy source of its own.

The reference's three crates are vendored (`crypto/vendor`), since
upstream is unmaintained, and built on a current arkworks. Every byte
that crosses the wire or is kept is fixed: keys, masked cards, shuffles,
every proof, and the Fiat–Shamir transcripts behind them, which keep the
reference's transcript encoding and ark-marlin's Fiat–Shamir generator.
Golden vectors written by the reference's own library hold this: the
deal's every call on fixed seeds, bent inputs and odd encodings among
them, replayed natively, over FFI and in the committed wasm
(`crypto/deal/tests/golden.rs`). So do two sealed games that library
kept, which the table's tests and the review page in the browser still
verify. One fix is the project's own: a point is normalised before it is
written into a proof's transcript. Otherwise a proof made from Jacobian
coordinates and checked from its serialised bytes would hash different
values, and every proof here crosses a wire.

### A batch of tokens under one argument

Each reveal token carries a Chaum–Pedersen proof that it was made with
the seat's committed key. A seat's 39 tokens are proved together
instead. Coefficients ρᵢ are taken from a hash of the key, the cards
and the tokens, and one argument shows log_G(pk) = log_H(B), where
H = Σ ρᵢ·C1ᵢ and B = Σ ρᵢ·Tᵢ. Getting any token wrong moves B off sk·H.
Moving it back would require knowing the ρᵢ before committing, and the
hash prevents that. The batch makes a seat's tokens round under a third
of the size of 39 tokens each with its own proof (`tokens_len` against
`TOKEN` in `crypto/deal/src/lib.rs`). A token
that travels alone, in a declaration, a play or a pass, carries its own
proof.

A token is checked once, on arrival, and stored bare. Opening a card
sums the tokens, and a sum has nothing left to check.

### A sealed token, and the argument that it is the right one

A pass seals each token to the receiver with ElGamal under the
receiver's deal key. Only the receiver can open it, so it needs a proof
that anyone can check. The passer knows its secret `sk` and the sealing
randomness `r`, which satisfy:

```text
    pk = sk·G                    the passer's key, already public
    c1 = r·G                     the seal's first half
    c2 = sk·C1 + r·pk_to         the token sk·C1, blinded to the receiver
```

A Σ-protocol over both witnesses (commit to a random pair, derive the
challenge from a hash of the statement, answer `z1 = a + c·sk` and
`z2 = b + c·r`) proves this without revealing the token. It is five
group elements and scalars (`SEAL_PROOF` in `crypto/deal/src/lib.rs`),
and every side checks it before it takes the pass. A pass that fails
the check is taken by nobody, and the passer's clock runs out at its
own turn. The receiver never has to complain about the token.

**Playing a card that was passed.** The passer's token for the card is the
receiver's to open, but playing the card means telling the table that
token, and the table has to be able to check it. A token that travels
alone carries a proof that it was made with the passer's key (96 bytes,
as for any token), and only the passer can make that. A pass that carried
it would have a problem on each side. In the clear it names the card:
the other three seats' tokens for the passer's positions are public, and
the 52 cards are fixed points, so there are 52 candidates for the
passer's token (the masked card's second half, less those three tokens,
less the card), and the proof verifies for exactly one of them. Hidden
inside the seal, nobody but the receiver could check it, so a passer could
hide a proof that does not verify beside a good seal, and every seat would
take the pass while the receiver could not open those cards. (An earlier
build did that.)

So the pass carries no proof of the token at all, only each seal and its
argument, every byte of which every side checks. When the receiver plays
the card it makes its own: the seal is a ciphertext of the same shape as
a masked card, so what a reveal token over it proves is that the
receiver's key opens it to a point. That is the token's `opening`:

```text
    pk_to = x·G                  the receiver's key, already public
    opening = x·c1               made over the seal's first half
    token = c2 − opening         the seal's second half, less the opening
```

With the seal's argument (`c2 = sk·C1 + r·pk_to`, `c1 = r·G`), that
leaves `sk·C1`, which is the passer's token for the card, and nobody had
to take the passer's word for it or the receiver's. The play carries the
opening in place of the token (`opening` instead of `token`, 128 bytes
like any token with its proof). Every side checks it against the
receiver's key and the seal it kept from the pass, takes the token out,
and opens the card with it. Nothing about the card is published before
the play, which names it anyway.

The opening needs the receiver's secret, so the seat that plays the card
makes it, or whoever plays for it once it has left and its secret is
rebuilt; the seed is drawn from the secret, so the same opening comes out
wherever it is made. A card passed in the clear, to a seat whose secret
was already public, is played with the passer's token whole, as every
card a seat plays from the hand it was dealt.

### The one fault no proof catches

A seat holding the 2♣ can claim not to hold it. There is no proof to
demand for a card you say you do not have. Every seat then says "not
me", and nobody can lead. The table responds by opening the hand where
it stands (the audit, called early) and giving it up: nothing is scored,
the seat the opened deal names is given to a bot for lying, and the next
hand is dealt in its place. A verifier sees the same thing. A hand
given up must show a seat that was dealt the 2♣ and disclaimed it, which
only that seat could have caused, so nobody can throw away a hand they
merely dislike.

## Seats nobody holds

A bot's hand must be hidden from the table too. If it is not, a table
of two people and two open bots shows each person 39 cards, and the
other person's hand is the thirteen left over. So at a sealed table
every bot seat is held by **the house**, the operator's own side at
every table ([the house](live-play.md#the-house)). The house makes the
seat's secret for each hand from a secret of its own, the seat and the
hand, so a house started again makes the same one and nobody else can.
It plays the bot's policy, shuffles with an argument and makes tokens
with proofs, and the table checks all of it without seeing the hand. A
bot seat's secret is published at the audit like everyone else's, so
the verifier can check every bot move was the policy's.

Because the house holds every bot seat, it holds every card a bot was
dealt. At a table of one person and three bots that is 39 cards, and the
person's hand is the thirteen left over: there the house can work out
the person's hand by subtraction, though no person can. With two or
more people at the table it holds at most 26 cards and cannot. The
privacy policy says so ([what the house can see](live-play.md#what-the-house-can-see)).

A seat whose person goes before they said their keys becomes a bot whose
secret anybody can compute from public values, and every side works out
its steps for the rest of that hand. That applies only where nobody drew
a secret for it. A secret drawn for a seat is never guessed.

## Escrow

A person's cards still have to open after they go. With their keys,
each person's seat escrows its deal secret, split in two by XOR, each
piece wrapped in a secret that the two table keys share (Diffie–Hellman
on the same curve). One piece goes to the house and the other to every
other person at the table. The house's piece and any one person's
rebuild the secret. The house alone holds noise, and so do all the
other people together. A person alone with bots has nobody to give the
second piece to, so their hand can be opened by nobody; when they go,
nobody is left at the table either, and the game ends. A seat the house
holds escrows to nobody, since nobody else may see its cards, and the
house can make its secret again.

When the table removes a person mid-hand before their hand is in the
open, every clock stops ([the escrow](table-states.md#the-escrow)). The
house and each other person say their piece once, as a release in the
log, in the clear: the seat is played by every side from there, so the
departed person's cards are open to the whole table for the rest of that
hand. Once the house's piece and one person's are in, the hand is open.
A hand still not open after the fixed clock (`fixedMs`) is given up,
unscored ([the abandoned hand](table-states.md#the-abandoned-hand)).

**Open.** Rebuilding a departed seat's secret opens that seat's whole
hand to the table. `crypto/deal` also has the primitives for an
alternative that opens only the positions still missing: a seat's key
split into two shares whose public keys add to the seat's own, and a
token from each share for each position (`split`, `shareKey`,
`shareToken`, `openShared`). Nothing uses them. Keys messages from
earlier builds carry such shares, each wrapped under the same pad as
the secret's piece beside it, which let anyone reading the log work out
a few bits of the secret. Every side still checks that their keys add
to the seat's, and nothing reads the shares. A keys message now leaves
the three fields empty.

## Verification

The verifier first holds every person's seat to its licence: one the
service signed for that seat's key, naming its account, and no account
seated twice ([the service](service.md)). Then it plays the referee's
log again with the same rules every side ran (`verifyRecord` in
`packages/table/lib/src/record.dart`). It checks every key's proof,
every shuffle's argument against the deck before it, every token and the
lead declaration. Then the audit's secrets open every card. Each play's
token must open the card it named, and each play is checked against the
hand it came from. A seat opened from the escrow is not audited, since
its released pieces stand in for its audit. A record that does not reach
the end of the game, or whose end the house did not sign for, is
rejected ([game records](live-play.md#game-records)).

Passes were made two other ways before this one. The first had each
token's proof in the clear beside its seal. The second hid it after the
seal, under a pad only the passer and the receiver could make, and played
the card with the passer's token whole. The two verifiers of kept games
(`verifyRecord` and the frozen `legacy/v2_record.dart`) still read both,
and the card each was played with, because games are kept for good
(`DealSession.readsOldPasses`). A table never does: it refuses a pass
with a field beside the seals, or with seals of any other size.

## Cost, and keeping it off the page

Roughly, a shuffle with its argument is the costly step: about a tenth of a
second natively, and three or four times that in a browser's wasm, with
checking one a little less. A token, sealed or not, takes a millisecond
or two to make or check natively, and a few in a browser. A four-person
hand costs each seat well under a second of its own work, a phone two
or three times that, and playing a card stays in the noise: one token
and its proof. What a person notices is the wait for the deal's rounds
to pass between the seats, each a trip through the referee.

Slow calls never run on the page's thread. The page runs the wasm in a
Web Worker, `app/web/deal_worker.js` (an isolate on the VM;
`packages/deal/lib/src/work.dart`). The session stays synchronous. A
side sends the slow calls its own step needs to the worker and makes the
step when they are back (`TableClient._workedOut`), and an entry whose
check needs slow calls waits to be taken until they are back
(`TableRules.waitingToTake`). When the session needs a slow result
itself, it stops, says what it needs (`DealSession.wanted`), and
continues from the answers (`resume`). Each answer is matched by a hash
of the call. A slow call that was not sent to the worker throws
(`PreparedDeal`), and the simulator's tests hold that count to zero. A
worker that fails, or makes no progress for several ticks, is replaced
once (`ResilientDealWorker` in `packages/deal/lib/src/work.dart`). The
ticks use the page's own timer, so a sleeping phone is not judged
stalled. If the replacement also fails, the device cannot deal
(`TableClient.cannotDeal`), and a seated device leaves at once and says
so.

Every live table is sealed. A device that cannot load the deal, or whose
worker does not start, does not go online: it opens no room and joins
no pool. A device that can deal refuses a start that is not sealed. The
web build ships the wasm. Android release builds bundle the native
library (`crypto/build_android.sh`), and iOS builds embed it as a
framework (`crypto/build_ios.sh`).

The house, started again mid-game, reads the whole log from its start,
so the VM signs and checks signatures with `crypto/schnorr` (k256, as
the browser's wasm) instead of pure-Dart BIP-340, which is many times
slower.

## What is guaranteed, and what is not

- **The deal cannot be rigged.** One honest shuffler is enough.
- **Nobody can see your cards**: not another player, and not the
  operator alone, with one exception (next). Opening your hand from the
  escrow takes the house's piece and another person's at your table,
  so you trust us not to collude with a player at your table. If you
  leave mid-hand, the rest of your hand is opened to the table and
  played from there (above).
- **The exception: alone with three bots.** The house holds every bot
  seat, so at a table of one person and three bots it can work out that
  person's hand by subtraction ([seats nobody holds](#seats-nobody-holds)).
- **Nobody can play a card they were not dealt**, because the masked
  card fixes its value.
- **Every game verifies end to end**, by anyone, after the fact.

Collusion outside the game (players sharing hands over a call), solver
assistance, and leaving early are not cryptographic problems. The first
two are out of scope, and the third is handled by clocks and the escrow.

## Solo games: where the randomness comes from

At a live table, each person's seat draws its deal secret and shuffle
seed, 32 bytes each, from `Random.secure()`; the house makes a bot
seat's secret from its own. In `crypto/deal` a seed drives ChaCha20 for
the permutation and the remasking. The table's 31-bit seed in the
signed start event picks the bots, and the bot that takes each seat a
person leaves. It is never relied on for secrecy.

A solo game has nobody to shuffle against, so the only question is
whether the shuffle is good (`packages/engine/lib/src/deal_seed.dart`):

- **The seed** is 256 bits from `Random.secure()`. That is more than the
  226 bits needed to number every order of the deck.
- **The generator** is HMAC-SHA-256 keyed by the seed. Hand `h` (the
  first is 0) reads from blocks `HMAC-SHA-256(seed, "deal" ‖ h ‖ b)` for
  `b` = 0, 1, 2 …. `"deal"` is four ASCII bytes, and `h` and `b` are four
  bytes each, big-endian. Each block gives eight 32-bit big-endian words
  in order. Without the seed, past hands say nothing about the next one.
- **The shuffle** is Fisher–Yates. The deck starts in index order
  (clubs, diamonds, spades, hearts, two to ace). For `i` from 51 down to
  1, position `i` swaps with a draw from `0 … i`. A draw from `0 … n−1`
  is the next word mod `n`, except that words in the top `2³² mod n` are
  rejected so every outcome is equally likely. Seat `s` gets positions
  `13s` to `13s + 12`, and seat 0 is the player.
- Nothing is wider than 32 bits, so the web deals exactly what the VM
  deals.

**The record** is the seed, the bots by name, and the player's passes
and plays. The bots are deterministic, so that is the whole game. It is
kept on the device, and **Copy record** on the game-over sheet produces:

```text
oh2:<seed, 64 hex digits>:<west>,<north>,<east>:<passes>:<plays>[:<target>]
```

Passes are three cards each, with `|` between hands and `-` for a hold
hand. The target appears only when it is not fifty. `oh1` records carry
an integer seed for `dart:math`'s `Random` and still replay. The tests
and tools name games the same way.

To replay a record, or to check a deal with nothing but Python, see
[Replay a solo game or check a deal by hand](../how-to/replay-a-game.md).

The seed is on the device, so a player who goes looking can read the
bots' hands in their own game. Nothing can prevent that in a game
against your own device. What is guaranteed is a uniform deal from an
unpredictable generator, reproduced exactly on every replay.

How the deal is tested is in [testing](testing.md#the-deal).

## References

- Shamir, Rivest and Adleman, *Mental Poker*, MIT LCS/TM-125, 1979.
- Goldwasser and Micali, [*Probabilistic encryption & how to play mental
  poker keeping secret all partial
  information*](https://dl.acm.org/doi/10.1145/800070.802212), STOC 1982.
- Schindelhauer, *A Toolbox for Mental Card Games*, University of
  Lübeck, 1998. Implemented by LibTMCG, which SecureSkat (peer-to-peer
  Skat, also a trick-taking game) is built on.
- Barnett and Smart, [*Mental Poker
  Revisited*](https://doi.org/10.1007/978-3-540-40974-8_29),
  Cryptography and Coding 2003, LNCS 2898, pp. 370–383.
- Bayer and Groth, [*Efficient Zero-Knowledge Argument for Correctness
  of a Shuffle*](https://doi.org/10.1007/978-3-642-29011-4_17),
  EUROCRYPT 2012.
- Neff, *A Verifiable Secret Shuffle and its Application to E-Voting*,
  CCS 2001.
