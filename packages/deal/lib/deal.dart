/// The verifiable deal's primitives, one interface over two builds of
/// the same Rust (crypto/deal): a cdylib the VM loads over FFI, and a
/// wasm the browser instantiates. Everything is bytes in, bytes out,
/// and deterministic in its inputs — randomness is a 32-byte seed the
/// caller draws.
///
/// Sizes are fixed (crypto/deal/src/lib.rs): a point 32 bytes, a
/// masked card 64, a deck of 52 masked cards 3328, a key proof 64, a
/// reveal token with its proof 128, a sealed token 64 with a 160-byte
/// argument after it. A shuffle proof is a few kilobytes. The Rust
/// reads a fixed-size input at its size whatever it is given, so both
/// bindings refuse an input of any other size before calling it: a
/// check is false, and a call that makes something throws. A pass
/// carries more than the Rust makes: the token's own proof, hidden,
/// after each seal ([passSealBytes]).
library;

import 'dart:typed_data';

import 'src/deal_binding.dart' if (dart.library.js_interop) 'src/deal_web.dart' as platform;

export 'src/session.dart';
export 'src/work.dart';

const deckSize = 52;
const pointBytes = 32;
const scalarBytes = 32;
const seedBytes = 32;
const maskedBytes = 64;
const deckBytes = deckSize * maskedBytes;
const keyProofBytes = 64;
const tokenBytes = 128;
const sealedBytes = 64;
const sealProofBytes = 160;

/// A token's proof: what follows its point in [tokenBytes].
const tokenProofBytes = tokenBytes - pointBytes;

/// A seal as a pass carries it: the sealed token ([sealedBytes]), the
/// argument that it is the right one ([sealProofBytes]), and after
/// them the token's own proof ([tokenProofBytes]) hidden from all but
/// the seat it is passed to. The proof is what makes the token whole
/// when that seat plays the card, and in the clear it would name the
/// card to anyone reading the log (docs/explanation/fair-deal.md).
const passSealBytes = sealedBytes + sealProofBytes + tokenProofBytes;

/// How many custodians have to answer to open a bot seat escrowed to
/// several, as a v2 game's jury held one: any two of them.
///
/// Two is the least that is still a secret — one custodian alone is
/// nothing, which is the whole point of a bot seat's hand being
/// hidden from a player with one custodian's help. Above two buys
/// secrecy against a wider ring at the cost of availability. A
/// refereed table's bot seats escrow to nobody: the house holds them.
const escrowThreshold = 2;

/// One argument for a batch of reveal tokens, however many
/// ([DealCrypto.revealTokens]).
const batchProofBytes = 96;

/// How long a batch of [n] tokens is on the wire.
int tokensBytes(int n) => n * pointBytes + batchProofBytes;

abstract class DealCrypto {
  /// The platform's binding, once it is ready: the wasm fetched on the
  /// web, the cdylib opened on the VM.
  static Future<DealCrypto> load({String? libraryPath}) => platform.load(libraryPath: libraryPath);

  /// A seat's public key from its 32-byte secret.
  Uint8List keygen(Uint8List secret);

  /// Proof of knowing the secret behind the key, bound to [name].
  Uint8List keyProof(Uint8List secret, Uint8List name, Uint8List seed);
  bool verifyKey(Uint8List pk, Uint8List name, Uint8List proof);

  /// The table's key: every seat's, summed.
  Uint8List aggregate(List<Uint8List> pks);

  /// The deck before anyone shuffles, from the joint key alone.
  Uint8List initialDeck(Uint8List joint);

  /// One seat's shuffle and remasking of [deck], drawn from [seed]:
  /// the new deck and the proof.
  ({Uint8List deck, Uint8List proof}) shuffle(Uint8List joint, Uint8List deck, Uint8List seed);
  bool verifyShuffle(Uint8List joint, Uint8List before, Uint8List after, Uint8List proof);

  /// This seat's share of opening [masked], with its proof — the
  /// token in the first [pointBytes], the proof after it. What is kept
  /// afterwards is the token alone: [unmask] adds tokens and addition
  /// has nothing to check.
  Uint8List revealToken(Uint8List secret, Uint8List masked, Uint8List seed);
  bool verifyToken(Uint8List pk, Uint8List masked, Uint8List token);

  /// The same for a run of cards at once, with one argument for the
  /// lot: [cards] masked cards end to end, answered with that many
  /// bare tokens in the same order and then [batchProofBytes].
  ///
  /// A proof is three times a token, and the proofs beside a seat's
  /// thirty-nine tokens at the deal would all say the same thing about
  /// the same key. One batch says it once — the tokens weighted by
  /// coefficients nobody chose, argued about together — and a seat
  /// that gets any one of them wrong fails the batch.
  Uint8List revealTokens(Uint8List secret, Uint8List cards, Uint8List seed);
  bool verifyTokens(Uint8List pk, Uint8List cards, Uint8List tokens);

  /// A seat's key split into [shares] pieces of [scalarBytes] each,
  /// so that a departed seat's cards can be opened without anyone
  /// putting the key back together (docs/explanation/fair-deal.md).
  /// [shareKey] of each aggregates to the seat's own public key, which
  /// is what says a split is a split of *that* key, and no smaller set
  /// of them is anything.
  Uint8List split(Uint8List secret, Uint8List seed, {int shares = 2});

  /// A secret of any length in [n] shares of the same length, any [t]
  /// of which rebuild it — the same shape [splitThreshold] gives a
  /// key, in the field bytes live in.
  ///
  /// A seat's *secret* is thirty-two bytes rather than a scalar, and
  /// it is what answers before the deck is dealt and at the audit, so
  /// it needs the threshold as much as the key does.
  Uint8List shareBytes(Uint8List secret, {required int n, required int t, required Uint8List seed});

  /// What the byte share at [index] is worth among the shares [have]
  /// holds, evaluated [at] an index: zero to rebuild the secret,
  /// another index to make that index's share.
  int bytesLagrange(List<int> have, int index, {int at = 0});

  /// A byte share scaled by its coefficient: what a holder sends,
  /// rather than the share.
  Uint8List bytesScale(Uint8List share, int by);

  /// Scaled byte shares summed — xor, in this field — into the secret,
  /// or into the share of whatever index they were scaled towards.
  Uint8List bytesSum(List<Uint8List> parts);

  /// A seat's key in [n] Shamir shares, any [t] of which rebuild it —
  /// where [split] makes shares that are all needed at once. Written
  /// in index order, [scalarBytes] each; a share's index is its place
  /// in the list counted from one, which is what [lagrange] takes.
  ///
  /// What it buys is availability: escrow among several holders, as a
  /// v2 game's jury was, rests on enough of them being reachable when
  /// a bot seat has to be opened. Any two of them keeps one
  /// holder alone from being anything, with room to lose people. The
  /// key is still never anywhere: a share's token is scaled by its
  /// public coefficient and the scaled tokens add.
  Uint8List splitThreshold(Uint8List secret, {required int n, required int t, required Uint8List seed});

  /// What the share at [index] is worth among the shares [have] holds,
  /// evaluated [at] an index: zero for the key itself, or another
  /// index to make *that* share — which is how a holder arriving later
  /// is given one without anybody rebuilding the key.
  Uint8List lagrange(List<int> have, int index, {int at = 0});

  /// Two scalars multiplied: a share by its coefficient, which is
  /// what a holder sends rather than the share.
  Uint8List scalarMul(Uint8List a, Uint8List b);

  /// Scalars added: the parts a newcomer is sent, summed into the
  /// share it holds from then on.
  Uint8List scalarSum(List<Uint8List> parts);

  /// A point scaled by a scalar: a share's key by its coefficient, so
  /// anybody can check the scaled token against it.
  Uint8List pointScale(Uint8List point, Uint8List scalar);

  /// One share's public key: what that share's token is checked
  /// against, and one of the keys the seat's own is the sum of.
  Uint8List shareKey(Uint8List share);

  /// The token behind a seal, from the parts the shares of the
  /// recipient's key made of it. A seal is a ciphertext of a card's
  /// shape, so a share's part is [shareToken] over the seal itself and
  /// [verifyToken] checks it; this adds them up and takes them off.
  /// [sealed] is the [sealedBytes] of ciphertext, as for [open].
  Uint8List openShared(Uint8List sealed, List<Uint8List> parts);

  /// One share's part of opening [masked], proved against that share's
  /// key exactly as a whole seat's token is proved against its own.
  /// Nothing combines them: [unmask] adds every token it is given, so
  /// a seat's shares go in as tokens beside the other seats' and the
  /// card comes out.
  Uint8List shareToken(Uint8List share, Uint8List masked, Uint8List seed);

  /// The card behind [masked] given every seat's token: the bare
  /// [pointBytes] tokens, with no proofs among them. A token is
  /// checked when it arrives — against its key, singly or in a batch —
  /// and opening is addition, which has nothing to check. [pks] says
  /// how many to expect and nothing else, and there must be as many
  /// [tokens]. Null if the sum is no card.
  int? unmask(List<Uint8List> pks, List<Uint8List> tokens, Uint8List masked);

  /// The token in what [revealToken] or [shareToken] wrote.
  static Uint8List tokenOf(Uint8List proved) => Uint8List.sublistView(proved, 0, pointBytes);

  /// A token for one seat's eyes: the share [secret]'s key owes for
  /// [masked], encrypted to [pkTo] — and after it, the argument that
  /// it is that share and not something else, which anybody can check
  /// without opening it ([verifySeal]). [sealedBytes] + [sealProofBytes].
  Uint8List seal(Uint8List secret, Uint8List pkTo, Uint8List masked, Uint8List seed);

  /// Whether a sealed token is the one [pkOwner] owes for [masked],
  /// sealed to [pkTo]. Checked by every seat, not only the one it is
  /// for: that is what catches a passer sending cards the receiver
  /// can never open (docs/explanation/fair-deal.md).
  bool verifySeal(Uint8List pkOwner, Uint8List pkTo, Uint8List masked, Uint8List sealed);

  /// The token inside a sealed one, with the key it was sealed to.
  /// [sealed] is the [sealedBytes] of ciphertext, without the argument.
  Uint8List open(Uint8List secret, Uint8List sealed);

  /// Thirty-two bytes two seats share and nobody else can compute,
  /// from this seat's secret and the other's key; the same from either
  /// side. A pass hides the proof of a token under it
  /// (`DealSession.passMessage`).
  Uint8List sharedSecret(Uint8List secret, Uint8List pk);
}

/// One masked card out of a deck.
Uint8List maskedAt(Uint8List deck, int index) => Uint8List.sublistView(deck, index * maskedBytes, (index + 1) * maskedBytes);
