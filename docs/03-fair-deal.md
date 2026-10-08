# 03 — The fair deal

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
- **Play.** A play is the token that opens a position for everyone. The
  card it opens must be the card named, so nobody can play a card they
  do not hold. The rules are checked as far as they can be without the
  hand, and the rest is checked at the audit.
- **Audit.** After the last trick every seat publishes its deal secret.
  Every card then opens, and every play is checked against the hand it
  came from.

All of this runs as turns of the table protocol
([doc 04](04-live-play.md), [doc 07](07-states.md)): four rounds before
the pass (keys, shuffle in seat order, tokens, lead declared) and the
audit after the last trick. Every step is checked by everyone when it
arrives. A seat that does not take its turn is removed like any other
silent seat.

One Rust crate builds twice. It builds as a cdylib that the Dart VM
loads over FFI (tests, the verifier, the service's juror), and as a
roughly 500 KB wasm that the browser loads with no glue code. Every random
value comes in as a seed from the caller. The wasm has no entropy source
of its own. The reference's three crates are vendored (`crypto/vendor`),
since upstream is unmaintained. They are ported from arkworks 0.3 to
0.6 with every byte that crosses the wire or is kept unchanged: keys,
masked cards, shuffles, every proof, and the Fiat–Shamir transcripts
behind them. 0.3's transcript encoding and ark-marlin's Fiat–Shamir
generator are kept as they were. A device on the older library and one
on the newer sit at one table, and every game the older one kept still
verifies. Golden vectors written by the 0.3 library hold this: the
deal's every call on fixed seeds, bent inputs and odd encodings among
them, replayed natively, over FFI and in the committed wasm
(`crypto/deal/tests/golden.rs`). So do two sealed games the 0.3 library
kept, verified by the table's tests and by the review page in the
browser. One fix is the project's own: a point is normalised before it
is written into a proof's transcript. Otherwise a proof made from
Jacobian coordinates and checked from its serialised bytes would hash
different values, and every proof here crosses a wire.

### A batch of tokens under one argument

Each reveal token carries a Chaum–Pedersen proof that it was made with
the seat's committed key. A seat's 39 tokens are proved together
instead. Coefficients ρᵢ are taken from a hash of the key, the cards
and the tokens, and one argument shows log_G(pk) = log_H(B), where
H = Σ ρᵢ·C1ᵢ and B = Σ ρᵢ·Tᵢ. Getting any token wrong moves B off sk·H.
Moving it back would require knowing the ρᵢ before committing, and the
hash prevents that. The batch cuts a seat's tokens round from 7,386
bytes to 2,169 (`reveal_tokens` in `crypto/deal/src/lib.rs`). A token
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
`z2 = b + c·r`) proves this without revealing the token. It is 160
bytes, and every seat checks it before accepting the pass. A pass that
fails the check never settles, and the passer's clock runs out at its
own turn. The receiver never has to complain.

### The one fault no proof catches

A seat holding the 2♣ can claim not to hold it. There is no proof to
demand for a card you say you do not have. Every seat then says "not
me", and nobody can lead. The table responds by opening the hand where
it stands (the audit, called early) and giving it up: nothing is scored,
the next hand is dealt in its place, and the seat the opened deal names
is removed at its next turn. A verifier sees the same thing. A hand
given up must show a seat that was dealt the 2♣ and disclaimed it, which
only that seat could have caused, so a majority cannot throw away a hand
it merely dislikes.

## Seats nobody holds

A bot's hand must be hidden from the table too. If it is not, a table
of two people and two open bots shows each person 39 cards, and the
other person's hand is the thirteen left over. So each bot seat is held
by a **juror** ([doc 04](04-live-play.md)). The juror draws the seat's
secret as a person would, plays the bot's policy, shuffles with an
argument and makes tokens with proofs. The table checks all of it
without seeing the hand. Each juror holds one bot seat, so no juror
holds enough cards to work out a person's hand by subtraction. The
juror for each seat is named by the jury draw the deal is sealed to,
and that draw is on the record ([doc 07](07-states.md)). A bot seat's
secret is published at the audit like everyone else's, so the verifier
can check every bot move was the policy's.

A seat whose holder goes before its keys are read becomes a bot whose
secret anybody can compute from public values. That applies only where
nobody drew a secret for it. A held bot seat's secret is never guessed.

## Escrow

A departed seat's cards still have to open. With its keys message, each
seat escrows its deal secret, wrapping each piece in a secret that the
two table keys share (Diffie–Hellman on the same curve):

- **A person's seat** is split in two by XOR. One piece goes to every
  other person and the other to every juror of the hand. Any one person
  plus any one juror can rebuild it. All the people together hold
  noise, and so does the whole jury. With no jury, the pieces go to the
  other people, and all of them are needed.
- **A bot seat a juror holds** is split into Shamir shares over GF(2⁸),
  one per juror, and any `escrowThreshold` (2) of them rebuild it. One
  juror alone has nothing. The pieces are released sealed to the other
  custodians while the hand is played, since a piece said in the clear
  would also be heard by the players. Once the hand is over they are
  released in the clear, with the audit. A juror drawn later gets a
  share of its own through `topUpPart`. Two holders each send what
  their share contributes at the newcomer's index, sealed to the
  newcomer, and the secret is never rebuilt anywhere in the process.

When the table removes a seat, each holder releases its piece, and
repeats the release every few seconds until the secret is known. The
seat's turns stall meanwhile, and the screen says so. A held bot seat
passes to the escrow when the record gives it there: the players claim
it at its turn when its juror is gone or out of time. If fewer than two
of its custodians remain and nobody who could open it is back within
twenty seconds, the game ends unscored as a connection failure
("juror quorum lost").

**Open.** Rebuilding a departed seat's secret opens that seat's whole
hand to whoever rebuilt it. `crypto/deal` and `DealSession` also
implement the alternative. A seat's key is split into a people's share
and a jury's share, whose public keys must add to the seat's own. In
play a holder then releases *share tokens* for exactly the positions
still missing (`split`, `shareKey`, `shareToken`, `openShared`,
`releaseShareTokens`). Survivors learn only the positions they open, and
the key is never reconstructed. Keys messages already carry the shares
and are checked against them, but the table still releases the secret
pieces. Wiring it in needs a pass sealed to a seat that has since left
to settle when its seal can open, not when it arrives.

## Verification

The verifier first holds every person's seat to its licence: one the
service signed for that seat's key, naming its account, and no account
seated twice ([doc 06](06-service.md)). Then it replays a sealed record
through the deal. It checks every key's proof, every shuffle's argument
against the deck before it, every token and the lead declaration. Then
the audit's secrets open every card. Each play's token must open the
card it named, and each play is checked against the hand it came from.
Until a hand's audit is in, its plays are checked as far as the rules
allow and the result is marked incomplete. A seat the record gave to the
escrow is not audited, since its released pieces stand in for its audit.
A record that continues past the end of the game is rejected.

## Cost, and keeping it off the page

Measured natively on arkworks 0.6: a shuffle with its argument takes
106 ms, checking one 72 ms, a token 0.7 ms to make and 1.2 ms to check,
and a sealed token 1.3 ms to make and 2.1 ms to check. A four-person
hand costs each seat well under a second of its own work. In V8, a
shuffle takes 380 ms, checking one 240 ms, and a seat's 39 tokens
103 ms to make and 92 ms to check. (On the same machine the library on
arkworks 0.3 took 124 and 108 ms natively, and 548, 455, 177 and
184 ms in V8, close to what was measured for it on a 2.8 GHz core:
566, 468, 199 and 190.) A phone is two or three times slower. Playing a
card stays in the noise: one token and its proof.

Slow calls never run on the page's thread. The page runs the wasm in a
Web Worker, `app/web/deal_worker.js` (an isolate on the VM;
`packages/deal/lib/src/work.dart`). The session stays synchronous. The
table sends the slow calls a step needs to the worker and parks the step
until they are back (`TableClient._workedOut`). When the session needs a
slow result itself, it stops, says what it needs (`DealSession.wanted`),
and continues from the answers (`resume`). Each answer is matched by a
hash of the call. A slow call that was not sent to the worker throws
(`PreparedDeal`), and the simulator's tests hold that count to zero.
A worker that fails, or makes no progress for six five-second ticks, is
replaced once (`ResilientDealWorker`). The ticks use the page's own
timer, so a sleeping phone is not judged stalled. If the replacement also
fails, the device cannot deal (`TableClient.cannotDeal`). Seated, it
leaves at once and says so. As a juror, it stops following the table,
and no table draws it again.

Every live table is sealed. A device that cannot load the deal, or whose
worker does not start, does not go online: it opens no room, joins no
pool, and is never drawn as a juror. A device that can deal refuses a
start that is not sealed. The web build ships the wasm. Android release
builds bundle the native library (`crypto/build_android.sh`). iOS builds
do not bundle it yet, so they play solo only.

A juror summoned mid-hand replays the whole hand's events, so the VM
signs with `crypto/schnorr` (k256, as the browser's wasm) instead of
pure-Dart BIP-340 at 17 ms a signature.

## What is guaranteed, and what is not

- **The deal cannot be rigged.** One honest shuffler is enough.
- **Nobody can see your cards**: not another player, not the operator,
  and not whoever is left at the table after you go. Any coalition able
  to open your hand must include a person at the table and a juror of
  the hand, and the juror is drawn at random. The exception is that a
  departed seat's hand is opened from escrow for the rest of that hand
  (above).
- **Nobody can play a card they were not dealt**, because the masked
  card fixes its value.
- **Every game verifies end to end**, by anyone, after the fact.

Collusion outside the game (players sharing hands over a call), solver
assistance, and leaving early are not cryptographic problems. The first
two are out of scope, and the third is handled by clocks and the escrow.

## Solo games: where the randomness comes from

At a live table, each seat (and each juror holding a bot seat) draws its
deal secret and shuffle seed, 32 bytes each, from `Random.secure()`. In
`crypto/deal` a seed drives ChaCha20 for the permutation and the
remasking. The table's 31-bit seed in the signed start event picks the
bots and draws the jury. It is never relied on for secrecy.

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

`cd packages/engine && dart run tool/replay.dart '<record>'` prints every
hand and trick. To check a deal without any of this code, the following
prints hand `h` (player, west, north, east) using only Python's standard
library:

```python
import hashlib, hmac, struct, sys

seed, hand = bytes.fromhex(sys.argv[1]), int(sys.argv[2])
words = []
for block in range(16):  # a deal needs seven blocks; sixteen is plenty
    mac = hmac.new(seed, b'deal' + struct.pack('>II', hand, block), hashlib.sha256)
    words += struct.unpack('>8I', mac.digest())
deck = list(range(52))
for i in range(51, 0, -1):
    n = i + 1
    while words[0] >= 2**32 - 2**32 % n:
        words.pop(0)
    j = words.pop(0) % n
    deck[i], deck[j] = deck[j], deck[i]
cards = [r + s for s in 'CDSH' for r in '2 3 4 5 6 7 8 9 10 J Q K A'.split()]
for seat in range(4):
    print(' '.join(cards[c] for c in sorted(deck[13 * seat:13 * seat + 13])))
```

The seed is on the device, so a player who goes looking can read the
bots' hands in their own game. Nothing can prevent that in a game
against your own device. What is guaranteed is a uniform deal from an
unpredictable generator, reproduced exactly on every replay.

## Tests

- `packages/deal`: every primitive round trips. Four sessions in one
  process deal, pass, play, lose a seat and rebuild it, and audit, and a
  verifier that saw only the messages checks the result. The share-token
  path opens a departed seat's hand and a pass sealed to it while
  `knowsSecret` stays false.
- `packages/table/test/sealed_test.dart`: whole sealed games at one, two
  and four people that verify to the end. It covers leaving mid-hand and
  during the deal, and a table of two surviving a crash through the jury.
  It also commits both faults for real, every seat disclaiming the 2♣ and
  a pass sealed to nothing, and each game still finishes and verifies.
- `service/test` runs the jury sealed over real sockets, and the browser
  suites deal every hand this way.
- `packages/engine/test/deal_seed_test.dart` and `solo_record_test.dart`
  cover the solo deal. They check the generator against known answers
  worked out in Python from this description, rejection of uneven draws,
  uniformity over all orders of four cards, and a χ² over 52 × 52
  positions that two broken shuffles fail. They also check that records
  of both versions replay trick for trick, on the VM and in Chrome.

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
