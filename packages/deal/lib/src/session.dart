/// One hand's deal, from one seat's side — or from nobody's, for a
/// juror following the table or the verifier. The protocol of
/// docs/03-fair-deal.md as a state machine over the primitives in
/// deal.dart: everyone's keys, four shuffles in seat order with their
/// arguments, reveal tokens for the other seats' positions, one's own
/// cards opened, the holder of the lead card declared; then, through
/// the hand, a pass as tokens sealed to the receiver, a play as the
/// token that opens its position for all, a departed seat's secret
/// rebuilt from the pieces it escrowed, and at the end every secret
/// revealed so the whole hand can be checked by anyone.
///
/// A bot seat has no secrets: its deal secret is a hash everyone can
/// compute, so its keys, shuffle and tokens are computed by everyone
/// rather than sent, and its hand is open to all — the interim doc 04
/// names, until the bot plays inside the computation. A person's hand
/// is known to that person alone until the audit; a person who leaves
/// becomes a bot whose secret the others rebuild.
///
/// **Escrow.** Each person splits their secret in two: one piece to
/// every other person at the table, one piece to every juror
/// (docs/04-live-play.md, "the jury"), each copy wrapped in the secret
/// the two keys share. Any one person and any one juror can rebuild it
/// once the table has removed the seat; all the people together hold
/// noise without a juror's piece, and the jury holds noise without a
/// person's. With no jury to escrow to, the pieces to the other
/// people are distinct and all of them are needed, so a second
/// departure in one hand cannot be played on — the jury is what a
/// sealed table is built for.
///
/// Messages are maps of plain values (bytes as base64) for the table
/// to carry in its events; every one is checked on arrival.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../deal.dart';

/// Where a deal stands.
enum DealPhase { keys, shuffles, tokens, declare, dealt, audited }

/// A seat as the deal sees it: a person, named by their table key, or
/// a bot.
sealed class DealSeat {
  const DealSeat();
}

class HumanDealSeat extends DealSeat {
  const HumanDealSeat(this.key);

  /// The seat's table key, hex: what its escrow pieces are wrapped to.
  final String key;
}

class BotDealSeat extends DealSeat {
  const BotDealSeat({this.key});

  /// The table key of the juror holding this seat, hex, at a live
  /// table; null in a solo game, where a bot's steps are public work
  /// everyone computes.
  final String? key;
}

const _seats = 4;
const _handSize = 13;

String _b64(Uint8List b) => base64.encode(b);
Uint8List _unb64(Object? s) => Uint8List.fromList(base64.decode(s as String));

class DealSession {
  DealSession(
    this.crypto, {
    required this.tableId,
    required this.tableSeed,
    required this.hand,
    required this.seats,
    required this.leadCard,
    this.mySeat,
    this.myKey,
    this.wrap,
    this.custodians = const [],
    Uint8List? mySecret,
    Random? random,
  })  : _random = random ?? Random.secure() {
    if (seats.length != _seats) throw ArgumentError('four seats');
    if (mySeat != null && !_keyed(mySeat!)) throw ArgumentError('a seat with a key of its own');
    if (mySeat != null && wrap == null) throw ArgumentError('a seat wraps its escrow');
    for (var s = 0; s < _seats; s++) {
      // A bot seat with no key is the solo game's, and everyone
      // computes it from what everyone knows. One a juror holds has a
      // secret of its own, and only its holder has it.
      if (!_keyed(s)) {
        _secrets[s] = botSecret(tableId, tableSeed, hand, s);
      } else if (s == mySeat) {
        _secrets[s] = mySecret ?? _draw();
      }
    }
    for (final s in _secrets.keys) {
      _pks[s] = crypto.keygen(_secrets[s]!);
    }
    _afterKeys(); // a table of one person and three bots has every key already
  }

  final DealCrypto crypto;
  final String tableId;
  final int tableSeed;
  final int hand;
  final List<DealSeat> seats;

  /// The card that leads the first trick, as a deck index: its holder
  /// declares it, since nobody else can see it.
  final int leadCard;

  /// This side's seat, or null for a follower.
  final int? mySeat;

  /// This side's table key, when it may be escrowed to as a juror.
  final String? myKey;

  /// The secret this side's key shares with another table key —
  /// Signer.sharedSecretWith — for wrapping escrow. Null for the
  /// verifier, which opens nothing.
  final Uint8List Function(String otherKey)? wrap;

  /// Table keys of the jurors this seat escrows to. Settable until
  /// the keys message is made, since a jury can carry after the hand
  /// opens.
  List<String> custodians;

  final Random _random;
  final Map<int, Uint8List> _secrets = {};
  final Map<int, Uint8List> _pks = {};
  final Map<int, Uint8List> _keyProofs = {};
  final Map<int, List<String>> _custodiansOf = {};
  Uint8List? _joint;
  final List<Uint8List> _decks = [];
  final Map<int, Uint8List> _shuffleProofs = {};

  /// Tokens by (seat that made it, position).
  final Map<int, Map<int, Uint8List>> _tokens = {};

  /// Tokens sealed to a seat, by position, kept until its secret is
  /// known here — the receiver's own, or a departed receiver's.
  final Map<int, Map<int, Uint8List>> _sealedTo = {};

  /// Cards opened, by position.
  final Map<int, int> _cards = {};

  /// Which seat holds each position now (passes move them; -1 played).
  late final List<int> _holderOf = [for (var p = 0; p < deckSize; p++) p ~/ _handSize];

  /// Which seat played each position, once played.
  final Map<int, int> _playedBy = {};

  /// The cards [seat] has played, in the order it played them — every
  /// one open, since a play opens its card for all. With [handOf], a
  /// view running behind the table rebuilds the hand as it stood
  /// before the plays it has yet to show.
  List<int> playedCardsOf(int seat) => [for (final e in _playedBy.entries) if (e.value == seat) _cards[e.key]!];

  /// The position each person declared the lead card at, or -1 for
  /// "not held".
  final Map<int, int> _declared = {};

  /// Pieces of other seats' secrets this side holds, by seat.
  final Map<int, Uint8List> _myPieceOf = {};

  /// This side's share of a seat's key, when it holds one: the
  /// people's share at a seat, the jury's at a juror. A share is not
  /// released — its tokens are.
  final Map<int, Uint8List> _myShareOf = {};

  /// A seat's two share keys, the people's then the jury's, as its
  /// keys message gave them. They add to the seat's own key, which is
  /// checked before the message is kept.
  final Map<int, List<Uint8List>> _shareKeysOf = {};

  /// Share tokens heard for a departed seat, by share index then
  /// position. Both shares' tokens for a position open it, beside the
  /// living seats', and the seat's key is never rebuilt.
  final Map<int, Map<int, Map<int, Uint8List>>> _shareTokens = {};

  /// Which of the two shares this side holds of a seat's key: 0 at a
  /// person, 1 at a juror.
  final Map<int, int> _myShareIndexOf = {};

  /// Parts of opening a seal made out to a departed seat, by share
  /// index then position: the point halves of tokens made over the
  /// seal itself.
  final Map<int, Map<int, Map<int, Uint8List>>> _sealParts = {};

  /// Pieces released for a departed seat, by the key that held them.
  final Map<int, Map<String, Uint8List>> _released = {};

  /// People who left: bots now, whose secrets the others rebuild.
  final Set<int> _gone = {};
  Set<int> get gone => Set.unmodifiable(_gone);

  /// A bot's deal secret: a hash of what everyone knows.
  static Uint8List botSecret(String tableId, int tableSeed, int hand, int seat) =>
      Uint8List.fromList(sha256.convert(utf8.encode('bot|$tableId|$tableSeed|$hand|$seat')).bytes);

  Uint8List _draw() => Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256)));

  Uint8List _name(int seat) => Uint8List.fromList(utf8.encode('$tableId|$hand|$seat'));

  /// A person's seat, as against a bot's however the bot is held: what
  /// escrow routing turns on, since a bot seat's pieces go to jurors
  /// alone (docs/04-live-play.md).
  bool _human(int seat) => seats[seat] is HumanDealSeat;

  /// A seat that holds a key of its own and so acts for itself: a
  /// person's, or a bot seat a juror holds. A bot seat without a key
  /// is the solo game's, and its steps are everyone's to compute.
  bool _keyed(int seat) => _keyOrNull(seat) != null;

  String? _keyOrNull(int seat) => switch (seats[seat]) {
        HumanDealSeat(:final key) => key,
        BotDealSeat(:final key) => key,
      };
  String _keyOf(int seat) => _keyOrNull(seat)!;

  // ---- where things stand ---------------------------------------------

  DealPhase get phase {
    if (_pks.length < _seats) return DealPhase.keys;
    if (_decks.length < _seats + 1) return DealPhase.shuffles;
    if (!_allTokensIn) return DealPhase.tokens;
    if (!_allDeclared) return DealPhase.declare;
    if (_secrets.length < _seats) return DealPhase.dealt;
    return DealPhase.audited;
  }

  /// Whether the seat's key is in: sent, or computed for a bot.
  bool hasKeys(int seat) => _pks.containsKey(seat);

  /// Whether this side knows the seat's deal secret: its own, a bot's,
  /// a departed seat's rebuilt, or anyone's after the audit.
  bool knowsSecret(int seat) => _secrets.containsKey(seat);

  /// A departed person this side still cannot answer for. Its secret
  /// rebuilt answers everything; so does holding both shares' tokens
  /// for every position still shut, which opens those positions and
  /// nothing else and leaves the key where it was (docs/03-fair-deal.md).
  bool awaitsSecret(int seat) =>
      _gone.contains(seat) && !_secrets.containsKey(seat) && !_coveredByShares(seat);

  /// Everything this side will ever be able to open of [seat] is to
  /// hand: both shares' tokens for every position it owes one for, and
  /// both parts of every seal made out to it.
  ///
  /// Nothing of a departed seat opens until this holds. The whole
  /// table above was built when a seat opened all at once — its secret
  /// arrived and every position of it fell open together — and the
  /// shares open it in stages, hand first and a seal whenever its
  /// parts arrive. Letting those stages show turns one moment into
  /// several, and a client that acted on the first found the rest
  /// missing. Opening on the last of them keeps the moment whole.
  bool _wholeForShares(int seat) {
    if (deck == null || _shareKeysOf[seat] == null) return false;
    final parts = _shareTokens[seat];
    if (parts == null) return false;
    for (var p = 0; p < deckSize; p++) {
      if (_tokens[seat]?[p] != null) continue;
      if (parts[0]?[p] == null || parts[1]?[p] == null) return false;
    }
    final sealed = _sealedTo[seat];
    if (sealed != null) {
      final sp = _sealParts[seat];
      for (final p in sealed.keys) {
        if (sp?[0]?[p] == null || sp?[1]?[p] == null) return false;
      }
    }
    return true;
  }

  /// The seat's hand is open here, and every position of its that is
  /// still shut has both of its shares' tokens.
  ///
  /// Holding both halves is not the same as the cards being open: a
  /// position needs the other three seats' tokens too. Saying
  /// "covered" on the halves alone stops the table waiting before
  /// there is anything to act on, and the release that would have
  /// opened the hand then arrives with nothing left to announce.
  bool _coveredByShares(int seat) {
    if (deck == null || _shareKeysOf[seat] == null) return false;
    final parts = _shareTokens[seat];
    if (parts == null || handOf(seat) == null) return false;
    for (var p = 0; p < deckSize; p++) {
      if (_cards.containsKey(p) || _tokens[seat]?[p] != null) continue;
      if (parts[0]?[p] == null || parts[1]?[p] == null) return false;
    }
    // A card behind a seal made out to this seat needs that seal's
    // parts, which are not its share tokens: the seal holds another
    // seat's token, and no amount of this seat's tokens opens it. A
    // pass heard after the last release is exactly the case the
    // release has to be sent again for, so staying uncovered here is
    // what asks for it (docs/03-fair-deal.md).
    final sealed = _sealedTo[seat];
    if (sealed != null) {
      final sp = _sealParts[seat];
      for (final p in sealed.keys) {
        if (_cards.containsKey(p)) continue;
        if (sp?[0]?[p] == null || sp?[1]?[p] == null) return false;
      }
    }
    return true;
  }

  bool get _allTokensIn {
    for (var s = 0; s < _seats; s++) {
      final t = _tokens[s];
      if (t == null) return false;
      for (var p = 0; p < deckSize; p++) {
        if (p ~/ _handSize != s && !t.containsKey(p)) return false;
      }
    }
    return true;
  }

  bool hasTokens(int seat) {
    final t = _tokens[seat];
    if (t == null) return false;
    for (var p = 0; p < deckSize; p++) {
      if (p ~/ _handSize != seat && !t.containsKey(p)) return false;
    }
    return true;
  }

  /// Whether the seat's word on the lead card is in — or not needed,
  /// its hand being open here.
  bool hasDeclared(int seat) => _declared.containsKey(seat) || handOf(seat) != null;

  bool get _allDeclared => Iterable<int>.generate(_seats).every(hasDeclared);

  /// The seat whose shuffle is awaited, or null once all four are in.
  int? get nextShuffler => _decks.isEmpty || _decks.length > _seats ? null : _decks.length - 1;

  bool hasShuffled(int seat) => _shuffleProofs.containsKey(seat);

  /// The dealt deck, once every shuffle is in.
  Uint8List? get deck => _decks.length == _seats + 1 ? _decks.last : null;

  Uint8List? pkOf(int seat) => _pks[seat];

  /// The seat's hand as this side knows it — every card, or null for a
  /// person's hand not opened here.
  List<int>? handOf(int seat) {
    final cards = <int>[];
    for (var p = 0; p < deckSize; p++) {
      if (_holderOf[p] != seat) continue;
      final c = _cards[p];
      if (c == null) return null;
      cards.add(c);
    }
    return cards;
  }

  /// The seat's hand as dealt — its thirteen positions' cards, passes
  /// and plays notwithstanding — as far as this side has opened them,
  /// or null if any is closed. What a replay of the hand starts from.
  List<int>? dealtHandOf(int seat) {
    final cards = <int>[];
    for (var p = seat * _handSize; p < (seat + 1) * _handSize; p++) {
      final c = _cards[p];
      if (c == null) return null;
      cards.add(c);
    }
    return cards;
  }

  /// How many positions [seat] holds.
  int handSizeOf(int seat) => _holderOf.where((h) => h == seat).length;

  /// The card at a position, if opened here.
  int? openedCardAt(int position) => _cards[position];

  /// The position of one of this side's open cards held by [seat].
  int? positionOf(int seat, int card) {
    for (var p = 0; p < deckSize; p++) {
      if (_holderOf[p] == seat && _cards[p] == card) return p;
    }
    return null;
  }

  int holderOf(int position) => _holderOf[position];

  /// Where the lead card is: declared by its holder, or seen in an
  /// open hand. Null until then — and for good when its holder lied.
  int? get leadPosition {
    for (var p = 0; p < deckSize; p++) {
      if (_cards[p] == leadCard) return p;
    }
    for (final e in _declared.entries) {
      if (e.value >= 0) return e.value;
    }
    return null;
  }

  /// The seat to lead the first trick: whoever holds the lead card's
  /// position now, passes counted.
  int? get leader {
    final p = leadPosition;
    return p == null ? null : _holderOf[p];
  }

  /// Whether every seat that gave its word on the lead card said it
  /// holds the card nowhere.
  ///
  /// On its own this is not a stalled hand: a bot's hand is open to
  /// everyone and a departed seat's opens from escrow, and either may
  /// hold the card, in which case every person saying "not me" is four
  /// true words and a hand that leads itself. It is a stalled hand
  /// together with [leader] being null, which says nothing open holds
  /// the card either — and then somebody lied, since one of the four
  /// thirteens has it.
  ///
  /// Only words go into it, so it is the same answer at every side of
  /// the table and stays the same answer afterwards: a seat removed
  /// later does not take its word back.
  bool get leadDisclaimed => _declared.isNotEmpty && _declared.values.every((p) => p < 0);

  /// Whether any departed seat's secret is still owed here: a hand
  /// this side cannot see yet, which may be the one holding the lead
  /// card. Nothing about the lead is settled while this is true.
  bool get awaitsAnySecret => _gone.any(awaitsSecret);

  /// The seat whose word on the lead card was false: it was dealt the
  /// card and said it holds it nowhere. Null until the deal is open
  /// enough to see the card — which, where every seat disclaimed it,
  /// takes the audit.
  int? get lied {
    final p = leadPosition;
    if (p == null) return null;
    final seat = dealtTo(p);
    return _declared[seat] == -1 ? seat : null;
  }

  // ---- keys ------------------------------------------------------------

  /// This seat's keys, for everyone, with its escrow: null when this
  /// side has no seat. Drawn once, so a re-send is the same message.
  Map<String, Object?>? myKeys() {
    final me = mySeat;
    if (me == null) return null;
    final cached = _myKeysMessage;
    if (cached != null) return cached;
    final secret = _secrets[me]!;
    final proof = _keyProofs[me] ??= crypto.keyProof(secret, _name(me), _draw());
    // Nobody at the table holds a piece of a bot seat: its escrow is
    // the jury's alone, both sides of it (docs/04-live-play.md). A
    // person's seat gives one to each of the other people.
    final others = _human(me) ? [for (var s = 0; s < _seats; s++) if (s != me && _human(s)) s] : const <int>[];
    final pieces = <String, String>{};
    final custody = <String>[];
    final shares = <String, String>{};
    final shareCustody = <String>[];
    final shareKeys = <String>[];
    if (custodians.isNotEmpty) {
      // One piece to each of the two sides the seat escrows across:
      // the other people and the jury for a person's seat, the jury
      // split in two for a bot seat a juror holds.
      if (_thresholdEscrow(me, custodians)) {
        // A bot seat's secret is the jury's alone, and in shares any
        // [escrowThreshold] of which rebuild it: one juror is still
        // nothing, and losing one no longer takes the seat with it.
        // A share's index is its custodian's place in the list,
        // counted from one, which is what the coefficients need.
        final shares = crypto.shareBytes(secret, n: custodians.length, t: escrowThreshold, seed: _seed('escrow', me));
        for (var i = 0; i < custodians.length; i++) {
          custody.add(_b64(_wrapFor(custodians[i], Uint8List.sublistView(shares, i * secret.length, (i + 1) * secret.length), me)));
        }
      } else {
        // A person's seat splits across the other people and the
        // jury: one live juror of any answers it, which is not the
        // shape that needed fixing.
        final (sideA, sideB) = _escrowSides(me, custodians);
        final first = _draw();
        final second = _xor(secret, first);
        for (final s in others) {
          pieces['$s'] = _b64(_wrapFor(_keyOf(s), first, me));
        }
        for (final j in custodians) {
          // Every juror gets its own entry at its own index, whichever
          // side it is on, so opening one is the same either way.
          custody.add(_b64(_wrapFor(j, sideA.contains(j) ? first : second, me)));
        }
      }
      // And the key itself in two shares, to the same holders. The
      // secret's pieces answer before the deck is dealt, where a
      // shuffle is still owed, and at the audit; in play it is the
      // shares' tokens that open a departed seat's positions, one at a
      // time, with the key never anywhere (docs/03-fair-deal.md).
      // Seeded from the secret, not drawn: an extra draw here would
      // move every draw after it and deal a different hand.
      final split = crypto.split(secret, _seed('shares', me), shares: 2);
      final ours = Uint8List.sublistView(split, 0, scalarBytes);
      final theirs = Uint8List.sublistView(split, scalarBytes);
      shareKeys.addAll([_b64(crypto.shareKey(ours)), _b64(crypto.shareKey(theirs))]);
      for (final s in others) {
        shares['$s'] = _b64(_wrapFor(_keyOf(s), ours, me));
      }
      for (final j in custodians) {
        shareCustody.add(_b64(_wrapFor(j, theirs, me)));
      }
    } else {
      // Distinct pieces to the people; all of them make the secret.
      var acc = Uint8List.fromList(secret);
      for (var i = 0; i < others.length; i++) {
        final piece = i == others.length - 1 ? acc : _draw();
        acc = _xor(acc, piece);
        pieces['${others[i]}'] = _b64(_wrapFor(_keyOf(others[i]), piece, me));
      }
    }
    return _myKeysMessage = {
      'seat': me,
      'pk': _b64(_pks[me]!),
      'proof': _b64(proof),
      'pieces': pieces,
      'custodians': custodians,
      'custody': custody,
      'shares': shares,
      'shareCustody': shareCustody,
      'shareKeys': shareKeys,
    };
  }

  Map<String, Object?>? _myKeysMessage;

  Uint8List _xor(Uint8List a, Uint8List b) => Uint8List.fromList([for (var i = 0; i < a.length; i++) a[i] ^ b[i]]);

  /// Whether [seat]'s secret is escrowed as a threshold over the whole
  /// jury rather than across two sides. A bot seat is, when there are
  /// enough custodians to make a threshold of; a person's seat is not,
  /// since its two sides are the other people and the jury, and one
  /// live juror of any answers that.
  bool _thresholdEscrow(int seat, List<String> custodians) => !_human(seat) && custodians.length >= escrowThreshold;

  /// The two sides a seat's secret is escrowed across, one piece each,
  /// so that one holder from each rebuilds it and neither side alone
  /// is anything.
  ///
  /// A person's seat splits across the other people and the jury. A
  /// bot seat splits the jury in two and gives the people nothing:
  /// a player with one juror's help is exactly what a bot's hand is
  /// hidden from, so handing players a piece would undo the whole of
  /// it (docs/04-live-play.md). The price is that a bot seat wants two
  /// live jurors where a person's wants one of each; with a jury of
  /// one the second side is empty and the seat cannot be opened at
  /// all, which is the table's business to avoid, not the deal's.
  (List<String>, List<String>) _escrowSides(int seat, List<String> jury) {
    if (_human(seat)) {
      return ([for (var s = 0; s < _seats; s++) if (s != seat && _human(s)) _keyOf(s)], jury);
    }
    final half = (jury.length + 1) ~/ 2;
    return (jury.take(half).toList(), jury.skip(half).toList());
  }

  /// A piece for the holder of [key], hidden under the secret this
  /// side shares with it and the piece's place.
  Uint8List _wrapFor(String key, Uint8List piece, int from) => _xor(piece, _pad(wrap!(key), 'escrow|$tableId|$hand|$from'));

  Uint8List _pad(Uint8List key, String label) => Uint8List.fromList(sha256.convert([...key, ...utf8.encode('|$label')]).bytes);

  /// Whether a seat's keys message is well formed and its proof
  /// holds. Changes nothing.
  bool verifyKeys(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (seat < 0 || seat >= _seats || !_keyed(seat)) return false;
      final pk = _unb64(m['pk']);
      final proof = _unb64(m['proof']);
      final custodianKeys = [for (final k in m['custodians'] as List) k as String];
      final custody = [for (final c in m['custody'] as List) _unb64(c)];
      if (custody.length != custodianKeys.length || custody.any((c) => c.length != 32)) return false;
      final pieces = Map<String, Object?>.from(m['pieces'] as Map);
      for (final e in pieces.entries) {
        final to = int.parse(e.key);
        if (to < 0 || to >= _seats || to == seat || _unb64(e.value).length != 32) return false;
      }
      // The key's shares, when the seat escrowed to a jury. Their keys
      // must add to the seat's own: that is what says they are shares
      // of this key and not of some other, and everyone checks it, not
      // only the two holders.
      final shareKeys = [for (final k in (m['shareKeys'] as List? ?? const [])) _unb64(k)];
      if (shareKeys.isNotEmpty) {
        if (shareKeys.length != 2 || shareKeys.any((k) => k.length != pointBytes)) return false;
        if (!_same(crypto.aggregate(shareKeys), pk)) return false;
        final shares = Map<String, Object?>.from(m['shares'] as Map? ?? const {});
        for (final e in shares.entries) {
          final to = int.parse(e.key);
          if (to < 0 || to >= _seats || to == seat || _unb64(e.value).length != scalarBytes) return false;
        }
        final shareCustody = [for (final c in (m['shareCustody'] as List? ?? const [])) _unb64(c)];
        if (shareCustody.length != custodianKeys.length || shareCustody.any((c) => c.length != scalarBytes)) return false;
      }
      return pk.length == pointBytes && crypto.verifyKey(pk, _name(seat), proof);
    } catch (_) {
      return false;
    }
  }

  /// Another seat's keys: kept when the proof holds, and whatever was
  /// escrowed to this side opened. False for a bot's, which everyone
  /// computes, and for anything that does not verify. [verified]
  /// skips the check for a message checked on arrival.
  bool acceptKeys(Map<String, Object?> m, {bool verified = false}) {
    try {
      final seat = m['seat'] as int;
      if (seat < 0 || seat >= _seats || !_keyed(seat)) return false;
      if (_pks.containsKey(seat)) {
        _afterKeys(); // the same seat again — or this side's own, whose keys were here from the start
        return true;
      }
      if (!verified && !verifyKeys(m)) return false;
      final pk = _unb64(m['pk']);
      final proof = _unb64(m['proof']);
      final custodianKeys = [for (final k in m['custodians'] as List) k as String];
      final custody = [for (final c in m['custody'] as List) _unb64(c)];
      final pieces = Map<String, Object?>.from(m['pieces'] as Map);
      _pks[seat] = pk;
      _keyProofs[seat] = proof;
      _custodiansOf[seat] = custodianKeys;
      final shareKeys = [for (final k in (m['shareKeys'] as List? ?? const [])) _unb64(k)];
      if (shareKeys.length == 2) _shareKeysOf[seat] = shareKeys;
      final shares = Map<String, Object?>.from(m['shares'] as Map? ?? const {});
      final shareCustody = [for (final c in (m['shareCustody'] as List? ?? const [])) _unb64(c)];
      final w = wrap;
      if (w != null) {
        final me = mySeat;
        final mine = me == null ? null : pieces['$me'];
        if (mine != null) {
          _myPieceOf[seat] = _xor(_unb64(mine), _pad(w(_keyOf(seat)), 'escrow|$tableId|$hand|$seat'));
        }
        final myShare = me == null ? null : shares['$me'];
        if (myShare != null) {
          _myShareOf[seat] = _xor(_unb64(myShare), _pad(w(_keyOf(seat)), 'escrow|$tableId|$hand|$seat'));
          _myShareIndexOf[seat] = 0; // the people's share
        }
        final k = myKey;
        final at = k == null ? -1 : custodianKeys.indexOf(k);
        if (at >= 0) {
          _myPieceOf[seat] = _xor(custody[at], _pad(w(_keyOf(seat)), 'escrow|$tableId|$hand|$seat'));
          if (at < shareCustody.length) {
            _myShareOf[seat] = _xor(shareCustody[at], _pad(w(_keyOf(seat)), 'escrow|$tableId|$hand|$seat'));
            _myShareIndexOf[seat] = 1; // the jury's share
          }
        }
      }
      _afterKeys();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A person has left the table. Without keys in yet, the seat is a
  /// bot from here, secret and all; with them, its secret is awaited
  /// from the pieces the others hold.
  void seatLeft(int seat) {
    if (!_keyed(seat) || _gone.contains(seat)) return;
    _gone.add(seat);
    if (!_pks.containsKey(seat)) {
      _secrets[seat] = botSecret(tableId, tableSeed, hand, seat);
      _pks[seat] = crypto.keygen(_secrets[seat]!);
      _afterKeys();
    }
  }

  void _afterKeys() {
    if (_pks.length < _seats || _joint != null) return;
    _joint = crypto.aggregate([for (var s = 0; s < _seats; s++) _pks[s]!]);
    _decks.add(crypto.initialDeck(_joint!));
    _computeWhatCan();
  }

  /// A seat whose steps are everyone's to compute: a bot's, or a
  /// departed person's once its secret is rebuilt. A person still at
  /// the table makes its own, even to a side that has come to know
  /// its secret — the verifier, reading the audit ahead.
  bool _public(int seat) => seat != mySeat && (!_keyed(seat) || _gone.contains(seat)) && _secrets.containsKey(seat);

  /// Every step of a seat whose secret is public here is public work:
  /// shuffles as far as they are next; and with the deck done, tokens
  /// for every seat whose secret this side holds, to open its cards.
  void _computeWhatCan() {
    while (nextShuffler != null && _public(nextShuffler!)) {
      final s = nextShuffler!;
      final r = crypto.shuffle(_joint!, _decks.last, _seed('shuffle', s));
      _decks.add(r.deck);
      _shuffleProofs[s] = r.proof;
    }
    if (deck == null) return;
    for (var s = 0; s < _seats; s++) {
      if (s != mySeat && _secrets.containsKey(s)) _tokensBy(s, everyPosition: true);
    }
    _openWhatCan();
  }

  /// A seat's secret from elsewhere — an audit read ahead — kept when
  /// it is the one behind the seat's key.
  bool provideSecret(int seat, Uint8List secret) {
    if (!_keyed(seat) || !_pks.containsKey(seat)) return false;
    if (_secrets.containsKey(seat)) return true;
    if (secret.length != 32 || !_same(crypto.keygen(secret), _pks[seat]!)) return false;
    _learnSecret(seat, secret);
    return true;
  }

  /// Public randomness for a bot seat's step: from its public secret.
  Uint8List _seed(String step, int seat) =>
      Uint8List.fromList(sha256.convert([...utf8.encode('$step|'), ..._secrets[seat]!]).bytes);

  // ---- shuffles --------------------------------------------------------

  /// This seat's shuffle, when it is next; null otherwise or done.
  Map<String, Object?>? myShuffle() {
    final me = mySeat;
    if (me == null || nextShuffler != me) return null;
    final r = crypto.shuffle(_joint!, _decks.last, _draw());
    _decks.add(r.deck);
    _shuffleProofs[me] = r.proof;
    _computeWhatCan();
    return {'seat': me, 'deck': _b64(r.deck), 'proof': _b64(r.proof)};
  }

  /// Whether a seat's shuffle is its to make now and its argument
  /// verifies against the deck before it. Changes nothing.
  bool verifyShuffle(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (nextShuffler != seat || !_keyed(seat) || _public(seat)) return false;
      final next = _unb64(m['deck']);
      final proof = _unb64(m['proof']);
      return next.length == deckBytes && crypto.verifyShuffle(_joint!, _decks.last, next, proof);
    } catch (_) {
      return false;
    }
  }

  /// A seat's shuffle: kept when it is that seat's turn and the
  /// argument verifies against the deck before it.
  bool acceptShuffle(Map<String, Object?> m, {bool verified = false}) {
    try {
      final seat = m['seat'] as int;
      if (_shuffleProofs.containsKey(seat)) return true;
      if (nextShuffler != seat || !_keyed(seat) || _public(seat)) return false;
      if (!verified && !verifyShuffle(m)) return false;
      final next = _unb64(m['deck']);
      final proof = _unb64(m['proof']);
      _decks.add(next);
      _shuffleProofs[seat] = proof;
      _computeWhatCan();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- tokens ----------------------------------------------------------

  /// Tokens by [seat] — whose secret this side holds — for every
  /// position, or for the other seats' alone.
  ///
  /// Kept bare: a token is 32 bytes, its proof 96, and the proof is
  /// spent the moment it is checked ([acceptTokens]). What opens a
  /// card is the sum of tokens, and a sum has nothing to check.
  void _tokensBy(int seat, {required bool everyPosition}) {
    final t = _tokens.putIfAbsent(seat, () => {});
    final want = [
      for (var p = 0; p < deckSize; p++)
        if ((everyPosition || p ~/ _handSize != seat) && t[p] == null) p,
    ];
    if (want.isEmpty) return;
    _spread(t, want, crypto.revealTokens(_secrets[seat]!, _cardsAt(want), _seed('tokens ${want.length}', seat)));
  }

  /// The bare tokens out of a batch, position by position.
  void _spread(Map<int, Uint8List> into, List<int> positions, Uint8List batch) {
    for (var i = 0; i < positions.length; i++) {
      into[positions[i]] = Uint8List.fromList(Uint8List.sublistView(batch, i * pointBytes, (i + 1) * pointBytes));
    }
  }

  Uint8List _masked(int p) => maskedAt(deck!, p);

  /// The masked cards at [positions], end to end, as a batch takes them.
  Uint8List _cardsAt(List<int> positions) => Uint8List.fromList([for (final p in positions) ..._masked(p)]);

  /// The positions a seat owes everyone a token for: every one but the
  /// thirteen it was dealt.
  List<int> _owed(int seat) => [for (var p = 0; p < deckSize; p++) if (p ~/ _handSize != seat) p];

  /// This seat's tokens for the other seats' positions; null before
  /// the deck is dealt or without a seat.
  ///
  /// One batch with one argument, not thirty-nine tokens each carrying
  /// a proof three times its own size: the proofs all said the same
  /// thing about the same key, and a batch says it once
  /// ([DealCrypto.revealTokens]).
  Map<String, Object?>? myTokens() {
    final me = mySeat;
    if (me == null || deck == null) return null;
    final owed = _owed(me);
    final batch = _myTokens ??= crypto.revealTokens(_secrets[me]!, _cardsAt(owed), _seed('tokens ${owed.length}', me));
    _spread(_tokens.putIfAbsent(me, () => {}), owed, batch);
    // And its own thirteen, which it needs to open its own cards and
    // nobody else ever sees.
    _tokensBy(me, everyPosition: true);
    _openWhatCan();
    return {'seat': me, 'tokens': _b64(batch)};
  }

  Uint8List? _myTokens;

  /// Whether a seat's tokens are one for every position not its own,
  /// each verifying against its key and the dealt deck. Changes
  /// nothing.
  bool verifyTokens(Map<String, Object?> m) => _checkTokens(m) != null;

  Map<int, Uint8List>? _checkTokens(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_keyed(seat) || deck == null || _public(seat)) return null;
      final owed = _owed(seat);
      final batch = _unb64(m['tokens']);
      if (batch.length != tokensBytes(owed.length)) return null;
      // One check for the lot, against the seat's key and the dealt
      // deck: a seat that gets any one token wrong fails it.
      if (!crypto.verifyTokens(_pks[seat]!, _cardsAt(owed), batch)) return null;
      final checked = <int, Uint8List>{};
      _spread(checked, owed, batch);
      return checked;
    } catch (_) {
      return null;
    }
  }

  /// A seat's tokens for the positions not its own, each checked
  /// against its key and the dealt deck.
  bool acceptTokens(Map<String, Object?> m, {bool verified = false}) {
    try {
      final seat = m['seat'] as int;
      if (!_keyed(seat) || deck == null || _public(seat)) return false;
      if (hasTokens(seat)) return true;
      final Map<int, Uint8List> checked;
      if (verified) {
        final owed = _owed(seat);
        final batch = _unb64(m['tokens']);
        if (batch.length != tokensBytes(owed.length)) return false;
        checked = {};
        _spread(checked, owed, batch);
      } else {
        final c = _checkTokens(m);
        if (c == null) return false;
        checked = c;
      }
      _tokens.putIfAbsent(seat, () => {}).addAll(checked);
      _openWhatCan();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens every position this side holds all four tokens for, and
  /// any token sealed to a seat whose secret it now knows.
  void _openWhatCan() {
    final d = deck;
    if (d == null) return;
    for (final e in List.of(_sealedTo.entries)) {
      final secret = _secrets[e.key];
      final parts = _sealParts[e.key];
      if (secret == null && !_wholeForShares(e.key)) continue;
      var every = true;
      for (final s in e.value.entries) {
        final p = s.key;
        final owner = p ~/ _handSize;
        if (_tokens[owner]?[p] != null) continue; // already opened, here
        // A seal that yields no token leaves its position shut, and
        // only that position: opening one is arithmetic that the
        // primitives refuse on a point that is not one, and a throw
        // from here used to take the whole session with it, so that
        // nothing else opened either. Nothing settled gets this far —
        // every seal is checked before its pass is taken
        // ([verifyPass]) — so this is the belt to that brace.
        try {
          final sealed = Uint8List.sublistView(s.value, 0, sealedBytes);
          final Uint8List point;
          if (secret != null) {
            point = crypto.open(secret, sealed);
          } else {
            // A seal is a ciphertext of a card's shape, so a share's
            // part of opening one is a token over the seal itself
            // (docs/03-fair-deal.md). Both parts, and the token the
            // departed key would have opened comes out.
            final a = parts![0]?[p];
            final b = parts[1]?[p];
            if (a == null || b == null) {
              every = false;
              continue;
            }
            point = crypto.openShared(sealed, [a, b]);
          }
          final token = Uint8List.fromList([...point, ...Uint8List.sublistView(s.value, sealedBytes + sealProofBytes)]);
          if (crypto.verifyToken(_pks[owner]!, _masked(p), token)) {
            _tokens.putIfAbsent(owner, () => {})[p] = DealCrypto.tokenOf(token);
            _passed.putIfAbsent(owner, () => {})[p] = token;
          }
        } catch (_) {}
      }
      // A seal whose parts have not arrived is kept: the release that
      // carries them may go out before a peer has heard the pass. A
      // departed seat's are kept whatever happens — this side makes
      // the parts other peers open them with, and a holder that threw
      // the seal away once it had served itself could never serve
      // anybody behind it again.
      if (every && !_gone.contains(e.key)) _sealedTo.remove(e.key);
    }
    for (var p = 0; p < deckSize; p++) {
      if (_cards.containsKey(p)) continue;
      final tokens = <Uint8List>[];
      final pks = <Uint8List>[];
      var whole = true;
      for (var s = 0; s < _seats; s++) {
        final t = _tokens[s]?[p];
        if (t != null) {
          tokens.add(t);
          pks.add(_pks[s]!);
          continue;
        }
        // A departed seat answers in two: its key's shares go in as two
        // tokens beside the other seats' — five keys where there were
        // four — and the card comes out with the key never rebuilt.
        final parts = _shareTokens[s];
        final keys = _shareKeysOf[s];
        final a = parts?[0]?[p];
        final b = parts?[1]?[p];
        if (keys == null || a == null || b == null || !_wholeForShares(s)) {
          whole = false;
          break;
        }
        tokens.addAll([DealCrypto.tokenOf(a), DealCrypto.tokenOf(b)]);
        pks.addAll([keys[0], keys[1]]);
      }
      if (!whole) continue;
      final c = crypto.unmask(pks, tokens, maskedAt(d, p));
      if (c != null) _cards[p] = c;
    }
  }

  // ---- the lead --------------------------------------------------------

  /// This seat's word on the lead card: the position it holds it at,
  /// with the token that opens it for everyone, or that it holds it
  /// nowhere. Null until its hand is open here.
  Map<String, Object?>? myDeclaration() {
    final me = mySeat;
    if (me == null || handOf(me) == null) return null;
    final p = positionOf(me, leadCard);
    if (p == null) return {'seat': me, 'position': -1};
    // With its proof, since it travels alone and nothing else here
    // vouches for it; what this side keeps is still the bare token.
    return {'seat': me, 'position': p, 'token': _b64(crypto.revealToken(_secrets[me]!, _masked(p), _seed('declare $p', me)))};
  }

  /// Whether a seat's word on the lead card holds: nowhere, or a
  /// position of its own at the deal that its token opens to the lead
  /// card. Changes nothing.
  bool verifyDeclaration(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_keyed(seat) || deck == null) return false;
      final p = m['position'] as int;
      if (p < 0) return true;
      if (p ~/ _handSize != seat) return false;
      return _openWith(seat, p, _unb64(m['token'])) == leadCard;
    } catch (_) {
      return false;
    }
  }

  /// The card at [p] given [token] as [owner]'s, without keeping
  /// either: null unless the token verifies and every other token for
  /// the position is in. Remembered, so that taking the same token
  /// after checking it costs nothing more.
  int? _openWith(int owner, int p, Uint8List token) {
    final seen = _checked[p];
    if (seen != null && _same(seen.token, token)) return seen.card;
    if (!crypto.verifyToken(_pks[owner]!, _masked(p), token)) return null;
    final tokens = <Uint8List>[];
    final pks = <Uint8List>[];
    for (var s = 0; s < _seats; s++) {
      final t = s == owner ? DealCrypto.tokenOf(token) : _tokens[s]?[p];
      if (t == null) return null;
      tokens.add(t);
      pks.add(_pks[s]!);
    }
    final card = crypto.unmask(pks, tokens, _masked(p));
    if (card != null) _checked[p] = (token: token, card: card);
    return card;
  }

  /// Positions opened in a check, with the token that did it.
  final Map<int, ({Uint8List token, int card})> _checked = {};

  /// Keeps a token that was checked to open [p]: the card without
  /// unmasking again.
  void _keepChecked(int owner, int p, Uint8List token) {
    // Bare in the store, proved beside it: the token that came in with
    // a play is the one this side would have to carry on if the
    // position moved again ([_proved]).
    _tokens.putIfAbsent(owner, () => {})[p] = DealCrypto.tokenOf(token);
    _passed.putIfAbsent(owner, () => {})[p] = token;
    final seen = _checked[p];
    if (seen != null && _same(seen.token, token)) _cards[p] ??= seen.card;
  }

  /// A seat's word on the lead card. A position must be the seat's
  /// own at the deal and open, with its token, to the lead card.
  bool acceptDeclaration(Map<String, Object?> m, {bool verified = false}) {
    try {
      final seat = m['seat'] as int;
      if (!_keyed(seat) || deck == null) return false;
      if (_declared.containsKey(seat)) return true;
      if (!verified && !verifyDeclaration(m)) return false;
      final p = m['position'] as int;
      if (p < 0) {
        _declared[seat] = -1;
        return true;
      }
      _keepChecked(seat, p, _unb64(m['token']));
      _openWhatCan();
      _declared[seat] = p;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- the hand --------------------------------------------------------

  /// The token that opens [position] for everyone: the one of the
  /// seat that held the position at the deal, which this side has if
  /// it is that seat or was passed the card.
  Map<String, Object?>? playToken(int position) {
    final owner = position ~/ _handSize;
    if (_tokens[owner]?[position] == null) return null;
    final proved = _proved(owner, position);
    if (proved == null) return null;
    return {'position': position, 'token': _b64(proved)};
  }

  /// The owner's token for [p] with its proof beside it. The store
  /// keeps tokens bare — a proof is spent when it is checked, and
  /// opening is addition — but a token that travels alone needs one,
  /// since nothing else vouches for it. Made here when this side holds
  /// the owner's secret; otherwise the one that came with the pass
  /// that handed the card over, which is the only other way to be
  /// holding somebody else's token at all.
  Uint8List? _proved(int owner, int p) {
    final secret = _secrets[owner];
    if (secret != null && deck != null) return crypto.revealToken(secret, _masked(p), _seed('play token $p', owner));
    return _passed[owner]?[p];
  }

  /// Tokens that arrived with a proof, kept whole for [_proved].
  final Map<int, Map<int, Uint8List>> _passed = {};

  /// The card a play would open — the position's missing token,
  /// checked against the key of the seat that held the position at
  /// the deal, the position [seat]'s now — or null. Changes nothing.
  int? verifyPlay(int seat, Map<String, Object?> m) {
    try {
      final p = m['position'] as int;
      if (p < 0 || p >= deckSize || _holderOf[p] != seat || deck == null) return null;
      return _openWith(p ~/ _handSize, p, _unb64(m['token']));
    } catch (_) {
      return null;
    }
  }

  /// A play: the position's missing token, checked against the key of
  /// the seat that held the position at the deal; the position must
  /// be [seat]'s now. Returns the card opened, or null.
  int? acceptPlay(int seat, Map<String, Object?> m, {bool verified = false}) {
    try {
      final p = m['position'] as int;
      if (p < 0 || p >= deckSize || _holderOf[p] != seat || deck == null) return null;
      final owner = p ~/ _handSize;
      final t = _unb64(m['token']);
      if (!verified && !crypto.verifyToken(_pks[owner]!, _masked(p), t)) return null;
      _keepChecked(owner, p, t);
      _openWhatCan();
      final card = _cards[p];
      if (card != null) {
        _holderOf[p] = -1; // played
        _playedBy[p] = seat;
      }
      return card;
    } catch (_) {
      return null;
    }
  }

  /// A play from a seat whose secret is public here — a bot's — needs
  /// no message: the position is just spent.
  bool playOpen(int seat, int position) {
    if (_holderOf[position] != seat || _cards[position] == null) return false;
    _holderOf[position] = -1;
    _playedBy[position] = seat;
    return true;
  }

  /// This seat's pass of [positions] to [to]: for each, the token that
  /// opens it — sealed to the receiver with the argument that it is the
  /// right token, or in the clear outright when the receiver's secret
  /// is public — and the positions, for all to see move.
  ///
  /// The argument is what makes a sealed pass checkable by the rest of
  /// the table. What is sealed is for one seat's eyes, so nobody else
  /// can look; the argument says, without looking, that what is in
  /// there is the share this seat's key owes for that card
  /// (docs/03-fair-deal.md). The reveal proof still travels beside it,
  /// in the clear, because it is what makes the opened point a whole
  /// token for the receiver to unmask with.
  ///
  /// A seat passes cards it was dealt, so every position here is its
  /// own at the deal: that is what the argument is about, and a pass of
  /// anything else is refused.
  Map<String, Object?>? passMessage(int to, List<int> positions) {
    final me = mySeat;
    final secret = _secrets[me];
    if (me == null || secret == null || deck == null) return null;
    final tokens = <Uint8List>[];
    for (final p in positions) {
      if (_holderOf[p] != me || p ~/ _handSize != me) return null;
      if (_tokens[me]?[p] == null) return null;
      // Made here rather than taken from the store, which keeps the
      // token alone: a pass needs the proof beside it, in the clear or
      // as the half that travels with a seal. Deterministic, so it is
      // the same token either way.
      tokens.add(crypto.revealToken(secret, _masked(p), _seed('pass token $p', me)));
    }
    if (_public(to)) {
      return {'from': me, 'to': to, 'positions': positions, 'tokens': [for (final t in tokens) _b64(t)]};
    }
    return {
      'from': me,
      'to': to,
      'positions': positions,
      'sealed': [for (final p in positions) _b64(crypto.seal(secret, _pks[to]!, _masked(p), _draw()))],
      'proofs': [for (final t in tokens) _b64(Uint8List.sublistView(t, pointBytes))],
    };
  }

  /// Whether a pass is well formed — positions the passer holds, a
  /// token for each, in the clear verifying, sealed the right size.
  /// Changes nothing.
  bool verifyPass(Map<String, Object?> m) {
    try {
      final from = m['from'] as int;
      final to = m['to'] as int;
      if (to < 0 || to >= _seats || to == from) return false;
      final positions = [for (final p in m['positions'] as List) p as int];
      if (positions.any((p) => p < 0 || p >= deckSize || _holderOf[p] != from || p ~/ _handSize != from)) return false;
      if (positions.toSet().length != positions.length) return false;
      final clear = m['tokens'];
      if (clear != null) {
        final tokens = [for (final t in clear as List) _unb64(t)];
        if (tokens.length != positions.length) return false;
        for (var i = 0; i < positions.length; i++) {
          final p = positions[i];
          if (!crypto.verifyToken(_pks[p ~/ _handSize]!, _masked(p), tokens[i])) return false;
        }
        return true;
      }
      final sealed = [for (final s in m['sealed'] as List) _unb64(s)];
      final proofs = [for (final s in m['proofs'] as List) _unb64(s)];
      if (sealed.length != positions.length || proofs.length != positions.length) return false;
      if (!sealed.every((s) => s.length == sealedBytes + sealProofBytes)) return false;
      if (!proofs.every((p) => p.length == tokenBytes - pointBytes)) return false;
      if (_pks[from] == null || _pks[to] == null) return false;
      // The argument each seal carries: what is sealed is the share
      // [from]'s key owes for that card. Checked by everyone, which is
      // the whole point of it — a receiver left with three cards it
      // cannot open used to be nobody else's business
      // (docs/03-fair-deal.md).
      for (var i = 0; i < positions.length; i++) {
        if (!crypto.verifySeal(_pks[from]!, _pks[to]!, _masked(positions[i]), sealed[i])) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A pass, from a person: the positions change hands; tokens in the
  /// clear are checked by all, sealed ones by whoever holds the
  /// receiver's secret — the receiver, or everyone once it has left.
  bool acceptPass(Map<String, Object?> m, {bool verified = false}) {
    try {
      if (!verified && !verifyPass(m)) return false;
      final from = m['from'] as int;
      final to = m['to'] as int;
      final positions = [for (final p in m['positions'] as List) p as int];
      if (positions.any((p) => p < 0 || p >= deckSize || _holderOf[p] != from || p ~/ _handSize != from)) return false;
      if (positions.toSet().length != positions.length) return false;
      final clear = m['tokens'];
      if (clear != null) {
        final tokens = [for (final t in clear as List) _unb64(t)];
        if (tokens.length != positions.length) return false;
        for (var i = 0; i < positions.length; i++) {
          final owner = positions[i] ~/ _handSize;
          // Checked just above; the store keeps the token alone, and
          // the proved one is kept beside it for the play that will
          // have to carry it on ([_proved]).
          _tokens.putIfAbsent(owner, () => {})[positions[i]] = DealCrypto.tokenOf(tokens[i]);
          _passed.putIfAbsent(owner, () => {})[positions[i]] = tokens[i];
        }
      } else {
        final sealed = [for (final s in m['sealed'] as List) _unb64(s)];
        final proofs = [for (final s in m['proofs'] as List) _unb64(s)];
        if (sealed.length != positions.length || proofs.length != positions.length) return false;
        final keep = _sealedTo.putIfAbsent(to, () => {});
        for (var i = 0; i < positions.length; i++) {
          // The ciphertext, its argument, and the reveal proof, kept
          // whole: the receiver opens the first, and the point that
          // comes out plus the last is the token it unmasks with.
          keep[positions[i]] = Uint8List.fromList([...sealed[i], ...proofs[i]]);
        }
      }
      for (final p in positions) {
        _holderOf[p] = to;
      }
      _openWhatCan();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A pass from a seat whose secret this side holds — a bot's, or
  /// its own once it has left and a bot plays its seat — needs no
  /// message: the positions move, and everyone can open them.
  bool passOpen(int from, int to, List<int> positions) {
    if (!_secrets.containsKey(from)) return false;
    if (positions.any((p) => _holderOf[p] != from)) return false;
    for (final p in positions) {
      _holderOf[p] = to;
    }
    return true;
  }

  // ---- escrow -----------------------------------------------------------

  /// This side's piece of a departed seat's secret, in the clear, for
  /// everyone: as a person or as a juror. Null when it holds none, or
  /// the seat is still here.
  Map<String, Object?>? releaseShare(int seat) {
    final piece = _myPieceOf[seat];
    final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
    if (piece == null || k == null || !_gone.contains(seat)) return null;
    return {'about': seat, 'holder': k, 'share': _b64(piece)};
  }

  // ---- topping the jury up ----------------------------------------------
  //
  // A jury only shrinks over a hand unless somebody is brought on, and
  // a newcomer holds nothing of a bot seat's secret until a share is
  // made for it. Two holders make one between them: each sends what
  // its own share is worth towards the newcomer's index, and the
  // newcomer sums them. Neither ever holds the secret, and what each
  // sends is worth nothing by itself (docs/04-live-play.md).

  /// Custodians added to [seat] after its keys went out. The index of
  /// a custodian is its place in the list counted from one, so this
  /// only ever appends — a newcomer inserted among the others would
  /// move every share after it onto the wrong index.
  void extendCustodians(int seat, List<String> added) {
    final have = _custodiansOf[seat];
    if (have == null) return;
    for (final k in added) {
      if (!have.contains(k)) have.add(k);
    }
  }

  /// This side's part of the share for the custodian at [at], made
  /// with the set [have] — indices, this side's among them — and
  /// sealed to the newcomer. Null when this side holds no piece of the
  /// seat, the seat is not escrowed as a threshold, or [have] is not a
  /// set this side is in.
  ///
  /// [have] travels with the part because it is what the part was
  /// weighed against: two holders that picked different sets make
  /// parts that do not go together, and the newcomer sums a set only
  /// once it has all of it.
  Map<String, Object?>? topUpPart(int seat, {required int at, required List<int> have}) {
    final piece = _myPieceOf[seat];
    final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
    final custodianKeys = _custodiansOf[seat];
    if (piece == null || k == null || custodianKeys == null || !_thresholdEscrow(seat, custodianKeys)) return null;
    final mine = custodianKeys.indexOf(k) + 1;
    if (mine < 1 || !have.contains(mine) || have.length < escrowThreshold) return null;
    if (at < 1 || at > custodianKeys.length || have.contains(at)) return null;
    final to = custodianKeys[at - 1];
    final part = crypto.bytesScale(piece, crypto.bytesLagrange(have, mine, at: at));
    // Sealed to the newcomer with the secret those two table keys
    // share, which is what [holder] is for: the sender wraps with the
    // recipient's key and the recipient unwraps with the sender's,
    // and they are the same secret.
    return {'about': seat, 'at': at, 'have': have, 'from': mine, 'holder': k, 'part': _b64(_wrapFor(to, part, seat))};
  }

  /// A part of this side's own new share. Kept by the set it was made
  /// with; once a set is complete the parts sum into the share this
  /// side holds from then on, and it is a custodian like any other.
  /// True once the part is kept.
  bool acceptTopUpPart(Map<String, Object?> m) {
    try {
      final about = m['about'] as int;
      final at = m['at'] as int;
      final from = m['from'] as int;
      final have = [for (final i in m['have'] as List) i as int];
      final custodianKeys = _custodiansOf[about];
      final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
      final w = wrap;
      if (custodianKeys == null || k == null || w == null) return false;
      if (at < 1 || at > custodianKeys.length || custodianKeys[at - 1] != k) return false;
      if (_myPieceOf[about] != null) return true;
      if (!have.contains(from) || have.contains(at) || have.length < escrowThreshold) return false;
      if (have.toSet().length != have.length) return false;
      if (have.any((i) => i < 1 || i > custodianKeys.length)) return false;
      // The sender's own key, and it has to be the custodian it says
      // it is: a part from anywhere else is not one of this set.
      final holder = m['holder'] as String;
      if (from < 1 || from > custodianKeys.length || custodianKeys[from - 1] != holder) return false;
      final part = _xor(_unb64(m['part']), _pad(w(holder), 'escrow|$tableId|$hand|$about'));
      final key = '$at|${have.join(',')}';
      final into = _topUp.putIfAbsent(about, () => {}).putIfAbsent(key, () => {});
      into[from] = part;
      if (!have.every(into.containsKey)) return true;
      _myPieceOf[about] = crypto.bytesSum([for (final i in have) into[i]!]);
      _topUp.remove(about);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Parts of a new share, by the seat and the set they were weighed
  /// against.
  final Map<int, Map<String, Map<int, Uint8List>>> _topUp = {};

  /// Whether this side holds a piece of [seat]'s secret — what says
  /// whether a top-up is owed to it.
  bool holdsPieceOf(int seat) => _myPieceOf[seat] != null;

  /// A released piece, by the table key that held it. Once a person's
  /// and a juror's — or, escrowed to no jury, every other person's —
  /// rebuild the secret behind the seat's key, the seat's hand is
  /// open. True once the piece is kept, whether or not that was the
  /// one that did it.
  bool acceptRelease(Map<String, Object?> m) {
    try {
      final about = m['about'] as int;
      final holder = m['holder'] as String;
      final piece = _unb64(m['share']);
      if (!_keyed(about) || !_gone.contains(about) || piece.length != 32) return false;
      final custodianKeys = _custodiansOf[about] ?? const <String>[];
      final threshold = _thresholdEscrow(about, custodianKeys);
      final (sideA, sideB) = threshold ? (custodianKeys, custodianKeys) : _escrowSides(about, custodianKeys);
      if (!sideA.contains(holder) && !sideB.contains(holder)) return false;
      if (_secrets.containsKey(about)) return true;
      final got = _released.putIfAbsent(about, () => {});
      got[holder] = piece;
      // This side's own piece counts, released or not.
      final own = _myPieceOf[about];
      final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
      if (own != null && k != null) got[k] = own;
      final pk = _pks[about]!;
      if (threshold) {
        // Any [escrowThreshold] of the custodians, each piece weighed
        // by what its index is worth among the ones that answered, and
        // summed. More than the threshold is the same secret, not a
        // different one, so everything in hand goes in.
        final have = [
          for (final who in got.keys)
            if (custodianKeys.contains(who)) custodianKeys.indexOf(who) + 1,
        ]..sort();
        if (have.length < escrowThreshold) return true;
        final secret = crypto.bytesSum([
          for (final i in have) crypto.bytesScale(got[custodianKeys[i - 1]]!, crypto.bytesLagrange(have, i)),
        ]);
        if (_same(crypto.keygen(secret), pk)) _learnSecret(about, secret);
        return true;
      }
      if (custodianKeys.isEmpty) {
        if (!sideA.every(got.containsKey)) return true;
        var secret = Uint8List(32);
        for (final k in sideA) {
          secret = _xor(secret, got[k]!);
        }
        if (_same(crypto.keygen(secret), pk)) _learnSecret(about, secret);
        return true;
      }
      // One holder from each side, whoever they are: two people at a
      // table with no jury, a person and a juror at a person's seat, or
      // two jurors at a bot seat.
      for (final s in sideA) {
        for (final j in sideB) {
          final a = got[s];
          final b = got[j];
          if (a == null || b == null) continue;
          final secret = _xor(a, b);
          if (_same(crypto.keygen(secret), pk)) {
            _learnSecret(about, secret);
            return true;
          }
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// This side's share of a departed seat's key, spent on the
  /// positions that seat's token is still missing from: one
  /// [DealCrypto.shareToken] each, proved against this side's share
  /// key and against nothing else. Null when this side holds no share
  /// of it, the seat is still here, the deck is not dealt, or nothing
  /// is missing.
  ///
  /// The share itself never goes anywhere. A share that crossed would
  /// hand the other side every position; a token crosses for one
  /// position and says nothing about the next (docs/03-fair-deal.md).
  Map<String, Object?>? releaseShareTokens(int seat) {
    final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
    if (k == null || deck == null || !_gone.contains(seat)) return null;
    final at = _mineIn(seat);
    if (at == null) return null;
    _mineSealsIn(seat);
    final mine = _shareTokens[seat]![at]!;
    final want = [for (var p = 0; p < deckSize; p++) if (mine[p] != null) p];
    final seals = _mySealParts(seat, at);
    if (want.isEmpty && seals.isEmpty) return null;
    return {
      'about': seat,
      'holder': k,
      'share': at,
      'tokens': {for (final p in want) '$p': _b64(mine[p]!)},
      'seals': seals,
    };
  }

  /// Files this side's own parts of the seals made out to [seat], for
  /// the same reason its own tokens are filed: each side holds one
  /// half, and they have to meet somewhere.
  void _mineSealsIn(int seat) {
    final at = _myShareIndexOf[seat];
    final share = _myShareOf[seat];
    final sealed = _sealedTo[seat];
    if (at == null || share == null || sealed == null) return;
    final into = _sealParts.putIfAbsent(seat, () => {}).putIfAbsent(at, () => {});
    for (final e in sealed.entries) {
      if (into.containsKey(e.key)) continue;
      final body = Uint8List.sublistView(e.value, 0, sealedBytes);
      final token = crypto.shareToken(share, body, _shareSeed('seal part ${e.key}', seat, share));
      into[e.key] = Uint8List.sublistView(token, 0, pointBytes);
    }
  }

  /// Makes this side's own share tokens for [seat], if it holds a
  /// share and has not made them, and returns which share they are of.
  /// Both sides must file their own as well as the other's, or each
  /// holds one half and neither opens anything.
  int? _mineIn(int seat) {
    final share = _myShareOf[seat];
    final at = _myShareIndexOf[seat];
    if (share == null || at == null || deck == null) return null;
    final into = _shareTokens.putIfAbsent(seat, () => {}).putIfAbsent(at, () => {});
    // What a release carries cannot depend on what this side happens
    // to hold. A holder that already has the seat's token for a
    // position would leave it out, a peer that has not would never get
    // it, and once the holders stop awaiting the seat they stop
    // re-sending — so the gap never closes. The seat's own positions
    // are the ones it never publishes a token for, so they are always
    // needed; if it went before its tokens, every position is.
    final every = !hasTokens(seat);
    for (var p = 0; p < deckSize; p++) {
      if (!every && p ~/ _handSize != seat) continue;
      if (into.containsKey(p)) continue;
      into[p] = crypto.shareToken(share, _masked(p), _shareSeed('share token $p', seat, share));
    }
    return at;
  }

  /// This side's parts of opening the seals made out to [seat]: a
  /// token over each seal itself, whole so that it can be checked,
  /// though only its point half does the opening. Recomputed each
  /// time, since a pass heard after the last release adds one — which
  /// is why a release goes out again whenever the seat is still
  /// awaited.
  Map<String, String> _mySealParts(int seat, int at) {
    final share = _myShareOf[seat];
    final sealed = _sealedTo[seat];
    if (share == null || sealed == null) return const {};
    final out = <String, String>{};
    for (final e in sealed.entries) {
      final body = Uint8List.sublistView(e.value, 0, sealedBytes);
      out['${e.key}'] = _b64(crypto.shareToken(share, body, _shareSeed('seal part ${e.key}', seat, share)));
    }
    return out;
  }

  /// Seeded from the share, which only its holders know: a re-sent
  /// release is then the same message, and no draw is spent — an extra
  /// draw moves every draw after it and deals a different hand.
  Uint8List _shareSeed(String step, int seat, Uint8List share) => Uint8List.fromList(
      sha256.convert([...utf8.encode('$step|$tableId|$hand|$seat|'), ...share]).bytes);

  /// A share's tokens for a departed seat, from the holder that made
  /// them. Each is checked against the share key it claims, so a
  /// holder cannot pass off another share's part as its own, nor a
  /// token for one position as a token for another. True once kept.
  bool acceptShareTokens(Map<String, Object?> m) {
    try {
      final about = m['about'] as int;
      if (!_keyed(about) || !_gone.contains(about) || deck == null) return false;
      final keys = _shareKeysOf[about];
      if (keys == null) return false;
      final at = m['share'] as int;
      if (at < 0 || at >= keys.length) return false;
      if (_secrets.containsKey(about)) return true;
      final tokens = Map<String, Object?>.from(m['tokens'] as Map);
      final into = _shareTokens.putIfAbsent(about, () => {}).putIfAbsent(at, () => {});
      var kept = false;
      for (final e in tokens.entries) {
        final p = int.parse(e.key);
        if (p < 0 || p >= deckSize || into.containsKey(p)) continue;
        final token = _unb64(e.value);
        if (token.length != tokenBytes) continue;
        if (!crypto.verifyToken(keys[at], _masked(p), token)) continue;
        into[p] = token;
        kept = true;
      }
      // The parts of opening the seals made out to it, checked the
      // same way: a token over the seal itself, against the share key
      // it claims.
      final seals = Map<String, Object?>.from(m['seals'] as Map? ?? const {});
      final sealsInto = _sealParts.putIfAbsent(about, () => {}).putIfAbsent(at, () => {});
      final sealed = _sealedTo[about];
      for (final e in seals.entries) {
        final p = int.parse(e.key);
        final blob = sealed?[p];
        if (blob == null || sealsInto.containsKey(p)) continue;
        final token = _unb64(e.value);
        if (token.length != tokenBytes) continue;
        final body = Uint8List.sublistView(blob, 0, sealedBytes);
        if (!crypto.verifyToken(keys[at], body, token)) continue;
        sealsInto[p] = Uint8List.sublistView(token, 0, pointBytes);
        kept = true;
      }
      // This side's own half, so that the two meet somewhere.
      _mineIn(about);
      _mineSealsIn(about);
      if (kept) _openWhatCan();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _learnSecret(int seat, Uint8List secret) {
    _secrets[seat] = secret;
    _computeWhatCan();
  }

  bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---- the audit --------------------------------------------------------

  /// This seat's secret, for everyone, once the hand is over — and
  /// every departed seat's this side rebuilt, so the record carries
  /// them without the pieces.
  Map<String, Object?>? myAudit() {
    final me = mySeat;
    if (me == null) return null;
    return {
      'seat': me,
      'secret': _b64(_secrets[me]!),
      'known': {for (final s in _gone) if (_secrets[s] != null) '$s': _b64(_secrets[s]!)},
    };
  }

  /// Whether a seat's audit holds: its secret is the one behind its
  /// key, and every secret it vouches for is behind that seat's.
  /// Changes nothing.
  bool verifyAudit(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_keyed(seat) || !_pks.containsKey(seat)) return false;
      final secret = _unb64(m['secret']);
      if (secret.length != 32 || !_same(crypto.keygen(secret), _pks[seat]!)) return false;
      final known = m['known'];
      if (known is Map) {
        for (final e in known.entries) {
          final s = int.parse(e.key as String);
          // A secret offered for a seat this side plays as a bot is
          // nothing to this side: a bot's secret is public work, and the
          // value offered cannot open a card differently. The side that
          // signed the audit may have held the seat as a person who left
          // — a seat removed at the first turn of a hand is a person to
          // the table and a bot to a verifier that reads the removal
          // before the deal — and either way this is what
          // [acceptAudit] passes over, so it is what this passes over.
          if (!_keyed(s)) continue;
          if (!_pks.containsKey(s)) return false;
          final other = _unb64(e.value);
          if (other.length != 32 || !_same(crypto.keygen(other), _pks[s]!)) return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A seat's secret at the audit, with any it vouches for: each kept
  /// when it is the one behind that seat's key; then every card those
  /// seats held is open.
  bool acceptAudit(Map<String, Object?> m, {bool verified = false}) {
    try {
      final seat = m['seat'] as int;
      if (!_keyed(seat)) return false;
      if (!verified && !verifyAudit(m)) return false;
      final secret = _unb64(m['secret']);
      if (!_secrets.containsKey(seat)) {
        _learnSecret(seat, secret);
      }
      final known = m['known'];
      if (known is Map) {
        for (final e in known.entries) {
          final s = int.parse(e.key as String);
          if (_secrets.containsKey(s) || !_keyed(s)) continue;
          _learnSecret(s, _unb64(e.value));
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Every position's card, once every secret is known.
  Map<int, int>? get fullDeal => _cards.length == deckSize ? Map.unmodifiable(_cards) : null;

  /// The seat that held each position at the deal, for the audit's
  /// replay: 0..3 by thirteens.
  static int dealtTo(int position) => position ~/ _handSize;
}
