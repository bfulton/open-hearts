/// The verifiable deal's primitives, one interface over two builds of
/// the same Rust (crypto/deal): a cdylib the VM loads over FFI, and a
/// wasm the browser instantiates. Everything is bytes in, bytes out,
/// and deterministic in its inputs — randomness is a 32-byte seed the
/// caller draws.
///
/// Sizes are fixed (crypto/deal/src/lib.rs): a point 32 bytes, a
/// masked card 64, a deck of 52 masked cards 3328, a key proof 64, a
/// reveal token with its proof 128, a sealed token 64 with a 160-byte
/// argument after it. A shuffle proof is a few kilobytes.
library;

import 'dart:typed_data';

import 'src/deal_binding.dart' if (dart.library.js_interop) 'src/deal_web.dart' as platform;

export 'src/session.dart';


const deckSize = 52;
const pointBytes = 32;
const scalarBytes = 32;
const maskedBytes = 64;
const deckBytes = deckSize * maskedBytes;
const keyProofBytes = 64;
const tokenBytes = 128;
const sealedBytes = 64;
const sealProofBytes = 160;

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

  /// This seat's share of opening [masked], with its proof.
  Uint8List revealToken(Uint8List secret, Uint8List masked, Uint8List seed);
  bool verifyToken(Uint8List pk, Uint8List masked, Uint8List token);

  /// A seat's key split into [shares] pieces of [scalarBytes] each,
  /// so that a departed seat's cards can be opened without anyone
  /// putting the key back together (docs/03-fair-deal.md, "Escrow").
  /// [shareKey] of each aggregates to the seat's own public key, which
  /// is what says a split is a split of *that* key, and no smaller set
  /// of them is anything.
  Uint8List split(Uint8List secret, Uint8List seed, {int shares = 2});

  /// One share's public key: what that share's token is checked
  /// against, and one of the keys the seat's own is the sum of.
  Uint8List shareKey(Uint8List share);

  /// The token behind a seal, from the parts the shares of the
  /// recipient's key made of it. A seal is a ciphertext of a card's
  /// shape, so a share's part is [shareToken] over the seal itself and
  /// [verifyToken] checks it; this adds them up and takes them off.
  Uint8List openShared(Uint8List sealed, List<Uint8List> parts);

  /// One share's part of opening [masked], proved against that share's
  /// key exactly as a whole seat's token is proved against its own.
  /// Nothing combines them: [unmask] adds every token it is given, so
  /// a seat's shares go in as tokens beside the other seats' and the
  /// card comes out.
  Uint8List shareToken(Uint8List share, Uint8List masked, Uint8List seed);

  /// The card behind [masked] given every seat's token, each checked
  /// against its key unless [verified] — for tokens checked on arrival,
  /// since checking a proof twice is most of the cost of a card; null
  /// if a token is bad or the result is no card.
  int? unmask(List<Uint8List> pks, List<Uint8List> tokens, Uint8List masked, {bool verified = false});

  /// A token for one seat's eyes: the share [secret]'s key owes for
  /// [masked], encrypted to [pkTo] — and after it, the argument that
  /// it is that share and not something else, which anybody can check
  /// without opening it ([verifySeal]). [sealedBytes] + [sealProofBytes].
  Uint8List seal(Uint8List secret, Uint8List pkTo, Uint8List masked, Uint8List seed);

  /// Whether a sealed token is the one [pkOwner] owes for [masked],
  /// sealed to [pkTo]. Checked by every seat, not only the one it is
  /// for: that is what stops a passer sending three cards the receiver
  /// can never open (docs/03-fair-deal.md).
  bool verifySeal(Uint8List pkOwner, Uint8List pkTo, Uint8List masked, Uint8List sealed);

  /// The token inside a sealed one, with the key it was sealed to.
  Uint8List open(Uint8List secret, Uint8List sealed);

  /// Thirty-two bytes two seats share and nobody else can compute,
  /// from this seat's secret and the other's key; the same from either
  /// side.
  Uint8List sharedSecret(Uint8List secret, Uint8List pk);
}

/// One masked card out of a deck.
Uint8List maskedAt(Uint8List deck, int index) => Uint8List.sublistView(deck, index * maskedBytes, (index + 1) * maskedBytes);
