/// Where a solo game's cards come from (docs/03-fair-deal.md, "Where the
/// randomness comes from").
///
/// A new game draws 256 bits from the platform's secure generator, and
/// every hand of it is computed from them: HMAC-SHA-256 keyed by the
/// seed, over the word "deal", the hand's number and a block counter,
/// read as 32-bit words; each word a Fisher–Yates draw, rejection
/// sampled so that no card is likelier anywhere than any other. 256 bits
/// is more than the 226 it takes to number every order of the deck, so
/// the seed is not what limits which deals can come; and the deals so
/// far say nothing about the next one to anybody without the seed.
///
/// The seed goes in the record (solo_record.dart), so the game replays
/// from it exactly, on the VM and on the web alike: nothing here is
/// wider than 32 bits, which is as wide as JavaScript does bitwise
/// arithmetic.
///
/// Games before this were dealt by `dart:math`'s [Random] from a 31-bit
/// seed, and still are wherever an int seed is given — every record made
/// then, and the tests and tools that name a game by a small number.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'card.dart';

/// 256 bits, and every deck a game is dealt from them.
class DealSeed {
  /// A seed from exactly [length] bytes.
  DealSeed(List<int> bytes) : _bytes = Uint8List.fromList(bytes) {
    if (bytes.length != length) throw ArgumentError('a deal seed is $length bytes, got ${bytes.length}');
  }

  /// A fresh seed from [Random.secure], which is the operating system's
  /// generator on the VM and `crypto.getRandomValues` on the web.
  factory DealSeed.draw() {
    final random = Random.secure();
    return DealSeed([for (var i = 0; i < length; i++) random.nextInt(256)]);
  }

  /// A seed from the [hex] a record carries: 64 hex digits. Null for
  /// anything else.
  static DealSeed? tryParse(String hex) {
    if (hex.length != length * 2 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
    return DealSeed([for (var i = 0; i < length; i++) int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)]);
  }

  static const length = 32;

  final Uint8List _bytes;

  List<int> get bytes => List.unmodifiable(_bytes);

  /// Lower-case, two digits a byte: how a record writes the seed.
  String get hex => [for (final b in _bytes) b.toRadixString(16).padLeft(2, '0')].join();

  /// The deck hand [hand] is dealt from, zero-based as a game counts
  /// its hands: seat `s` holds the thirteen cards from `13·s`. The deck
  /// starts in [Card.deck] order, and each position from the last down
  /// to the second swaps with one at or below it, drawn from
  /// [DealStream].
  List<Card> deck(int hand) => DealStream(this, hand).shuffle(Card.deck);

  @override
  bool operator ==(Object other) => other is DealSeed && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => hex;
}

/// The words one hand's shuffle draws: block `b` is
/// HMAC-SHA-256(seed, "deal" ‖ hand ‖ b), the hand and the block four
/// bytes each, big-endian, and each block eight 32-bit big-endian words
/// taken in order.
class DealStream {
  DealStream(DealSeed seed, this.hand) : _mac = Hmac(sha256, seed._bytes) {
    RangeError.checkValueInInterval(hand, 0, _words - 1, 'hand');
  }

  final int hand;
  final Hmac _mac;
  ByteData? _block;
  var _blocks = 0;
  var _used = 0;

  static final _label = ascii.encode('deal');

  /// The next word, `0 ≤ w < 2³²`.
  int nextWord() {
    if (_block == null || _used == 8) {
      final message = ByteData(_label.length + 8);
      for (var i = 0; i < _label.length; i++) {
        message.setUint8(i, _label[i]);
      }
      message.setUint32(_label.length, hand);
      message.setUint32(_label.length + 4, _blocks++);
      _block = ByteData.sublistView(Uint8List.fromList(_mac.convert(message.buffer.asUint8List()).bytes));
      _used = 0;
    }
    return _block!.getUint32(4 * _used++);
  }

  /// A number in `0 ≤ k < n`, every one of them equally likely: a word
  /// from the top `2³² mod n` values, which would favour the low
  /// numbers, is thrown away and the next one drawn. For a deck that is
  /// at most 48 values in four billion.
  int below(int n) => uniformBelow(n, nextWord);

  /// [items] in the order this stream shuffles them: Fisher–Yates, from
  /// the last position down.
  List<T> shuffle<T>(List<T> items) {
    final out = List.of(items);
    for (var i = out.length - 1; i > 0; i--) {
      final j = below(i + 1);
      final t = out[i];
      out[i] = out[j];
      out[j] = t;
    }
    return out;
  }
}

/// `2³²`, which a double holds exactly: the arithmetic below is the same
/// in JavaScript as on the VM.
const _words = 0x100000000;

/// A number in `0 ≤ k < n` from 32-bit [word]s, rejection sampled: see
/// [DealStream.below].
int uniformBelow(int n, int Function() word) {
  if (n < 1 || n > _words) throw RangeError.range(n, 1, _words, 'n');
  final limit = _words - _words % n;
  while (true) {
    final w = word();
    if (w < limit) return w % n;
  }
}
