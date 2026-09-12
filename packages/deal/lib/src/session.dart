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
  const BotDealSeat();
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
    List<String> custodians = const [],
    Uint8List? mySecret,
    Random? random,
  })  : _random = random ?? Random.secure(),
        custodians = List.unmodifiable(custodians) {
    if (seats.length != _seats) throw ArgumentError('four seats');
    if (mySeat != null && seats[mySeat!] is! HumanDealSeat) throw ArgumentError('a person\'s seat');
    if (mySeat != null && wrap == null) throw ArgumentError('a seat wraps its escrow');
    for (var s = 0; s < _seats; s++) {
      if (seats[s] is BotDealSeat) {
        _secrets[s] = botSecret(tableId, tableSeed, hand, s);
      } else if (s == mySeat) {
        _secrets[s] = mySecret ?? _draw();
      }
    }
    for (final s in _secrets.keys) {
      _pks[s] = crypto.keygen(_secrets[s]!);
    }
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

  /// Table keys of the jurors this seat escrows to.
  final List<String> custodians;

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

  /// The position each person declared the lead card at, or -1 for
  /// "not held".
  final Map<int, int> _declared = {};

  /// Pieces of other seats' secrets this side holds, by seat.
  final Map<int, Uint8List> _myPieceOf = {};

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

  bool _human(int seat) => seats[seat] is HumanDealSeat;
  String _keyOf(int seat) => (seats[seat] as HumanDealSeat).key;

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

  /// A departed person whose secret has yet to be rebuilt: nothing of
  /// theirs can be computed until it is.
  bool awaitsSecret(int seat) => _gone.contains(seat) && !_secrets.containsKey(seat);

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
    final others = [for (var s = 0; s < _seats; s++) if (s != me && _human(s)) s];
    final pieces = <String, String>{};
    final custody = <String>[];
    if (custodians.isNotEmpty) {
      // One piece to every person, one to every juror.
      final toSeats = _draw();
      final toJury = _xor(secret, toSeats);
      for (final s in others) {
        pieces['$s'] = _b64(_wrapFor(_keyOf(s), toSeats, me));
      }
      for (final j in custodians) {
        custody.add(_b64(_wrapFor(j, toJury, me)));
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
    };
  }

  Map<String, Object?>? _myKeysMessage;

  Uint8List _xor(Uint8List a, Uint8List b) => Uint8List.fromList([for (var i = 0; i < a.length; i++) a[i] ^ b[i]]);

  /// A piece for the holder of [key], hidden under the secret this
  /// side shares with it and the piece's place.
  Uint8List _wrapFor(String key, Uint8List piece, int from) => _xor(piece, _pad(wrap!(key), 'escrow|$tableId|$hand|$from'));

  Uint8List _pad(Uint8List key, String label) => Uint8List.fromList(sha256.convert([...key, ...utf8.encode('|$label')]).bytes);

  /// Another seat's keys: kept when the proof holds, and whatever was
  /// escrowed to this side opened. False for a bot's, which everyone
  /// computes, and for anything that does not verify.
  bool acceptKeys(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (seat < 0 || seat >= _seats || !_human(seat)) return false;
      if (_pks.containsKey(seat)) return true; // the same seat again
      final pk = _unb64(m['pk']);
      final proof = _unb64(m['proof']);
      if (!crypto.verifyKey(pk, _name(seat), proof)) return false;
      final custodianKeys = [for (final k in m['custodians'] as List) k as String];
      final custody = [for (final c in m['custody'] as List) _unb64(c)];
      if (custody.length != custodianKeys.length) return false;
      final pieces = Map<String, Object?>.from(m['pieces'] as Map);
      _pks[seat] = pk;
      _keyProofs[seat] = proof;
      _custodiansOf[seat] = custodianKeys;
      final w = wrap;
      if (w != null) {
        final me = mySeat;
        final mine = me == null ? null : pieces['$me'];
        if (mine != null) {
          _myPieceOf[seat] = _xor(_unb64(mine), _pad(w(_keyOf(seat)), 'escrow|$tableId|$hand|$seat'));
        }
        final k = myKey;
        final at = k == null ? -1 : custodianKeys.indexOf(k);
        if (at >= 0) {
          _myPieceOf[seat] = _xor(custody[at], _pad(w(_keyOf(seat)), 'escrow|$tableId|$hand|$seat'));
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
    if (!_human(seat) || _gone.contains(seat)) return;
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

  /// A seat whose secret everyone holds: a bot's, a departed
  /// person's once rebuilt, anyone's after the audit. This side's own
  /// is not public, however well it knows it.
  bool _public(int seat) => seat != mySeat && _secrets.containsKey(seat);

  /// Every step of a seat whose secret is public here is public work:
  /// shuffles as far as they are next, tokens, the lead card found.
  void _computeWhatCan() {
    while (nextShuffler != null && _public(nextShuffler!)) {
      final s = nextShuffler!;
      final r = crypto.shuffle(_joint!, _decks.last, _seed('shuffle', s));
      _decks.add(r.deck);
      _shuffleProofs[s] = r.proof;
    }
    if (deck == null) return;
    for (var s = 0; s < _seats; s++) {
      if (_public(s)) _tokensBy(s, everyPosition: true);
    }
    _openWhatCan();
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

  /// A seat's shuffle: kept when it is that seat's turn and the
  /// argument verifies against the deck before it.
  bool acceptShuffle(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (_shuffleProofs.containsKey(seat)) return true;
      if (nextShuffler != seat || !_human(seat) || _public(seat)) return false;
      final next = _unb64(m['deck']);
      final proof = _unb64(m['proof']);
      if (next.length != deckBytes || !crypto.verifyShuffle(_joint!, _decks.last, next, proof)) return false;
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
  void _tokensBy(int seat, {required bool everyPosition}) {
    final t = _tokens.putIfAbsent(seat, () => {});
    for (var p = 0; p < deckSize; p++) {
      if (!everyPosition && p ~/ _handSize == seat) continue;
      t[p] ??= crypto.revealToken(_secrets[seat]!, _masked(p), _seed('token $p', seat));
    }
  }

  Uint8List _masked(int p) => maskedAt(deck!, p);

  /// This seat's tokens for the other seats' positions; null before
  /// the deck is dealt or without a seat.
  Map<String, Object?>? myTokens() {
    final me = mySeat;
    if (me == null || deck == null) return null;
    _tokensBy(me, everyPosition: true);
    final t = _tokens[me]!;
    _openWhatCan();
    return {
      'seat': me,
      'tokens': {for (var p = 0; p < deckSize; p++) if (p ~/ _handSize != me) '$p': _b64(t[p]!)},
    };
  }

  /// A seat's tokens for the positions not its own, each checked
  /// against its key and the dealt deck.
  bool acceptTokens(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_human(seat) || deck == null || _public(seat)) return false;
      if (hasTokens(seat)) return true;
      final pk = _pks[seat]!;
      final given = Map<String, Object?>.from(m['tokens'] as Map);
      final checked = <int, Uint8List>{};
      for (var p = 0; p < deckSize; p++) {
        if (p ~/ _handSize == seat) continue;
        final t = _unb64(given['$p']);
        if (!crypto.verifyToken(pk, _masked(p), t)) return false;
        checked[p] = t;
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
      if (secret == null) continue;
      for (final s in e.value.entries) {
        final p = s.key;
        final owner = p ~/ _handSize;
        final point = crypto.open(secret, Uint8List.sublistView(s.value, 0, sealedBytes));
        final token = Uint8List.fromList([...point, ...Uint8List.sublistView(s.value, sealedBytes)]);
        if (crypto.verifyToken(_pks[owner]!, _masked(p), token)) _tokens.putIfAbsent(owner, () => {})[p] = token;
      }
      _sealedTo.remove(e.key);
    }
    for (var p = 0; p < deckSize; p++) {
      if (_cards.containsKey(p)) continue;
      final tokens = <Uint8List>[];
      final pks = <Uint8List>[];
      for (var s = 0; s < _seats; s++) {
        final t = _tokens[s]?[p];
        if (t == null) break;
        tokens.add(t);
        pks.add(_pks[s]!);
      }
      if (tokens.length < _seats) continue;
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
    return {'seat': me, 'position': p, 'token': _b64(_tokens[me]![p]!)};
  }

  /// A seat's word on the lead card. A position must be the seat's
  /// own at the deal and open, with its token, to the lead card.
  bool acceptDeclaration(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_human(seat) || deck == null) return false;
      if (_declared.containsKey(seat)) return true;
      final p = m['position'] as int;
      if (p < 0) {
        _declared[seat] = -1;
        return true;
      }
      if (p ~/ _handSize != seat) return false;
      final t = _unb64(m['token']);
      if (!crypto.verifyToken(_pks[seat]!, _masked(p), t)) return false;
      _tokens.putIfAbsent(seat, () => {})[p] = t;
      _openWhatCan();
      if (_cards[p] != leadCard) return false;
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
    final t = _tokens[owner]?[position];
    if (t == null) return null;
    return {'position': position, 'token': _b64(t)};
  }

  /// A play: the position's missing token, checked against the key of
  /// the seat that held the position at the deal; the position must
  /// be [seat]'s now. Returns the card opened, or null.
  int? acceptPlay(int seat, Map<String, Object?> m) {
    try {
      final p = m['position'] as int;
      if (p < 0 || p >= deckSize || _holderOf[p] != seat || deck == null) return null;
      final owner = p ~/ _handSize;
      final t = _unb64(m['token']);
      if (!crypto.verifyToken(_pks[owner]!, _masked(p), t)) return null;
      _tokens.putIfAbsent(owner, () => {})[p] = t;
      _openWhatCan();
      final card = _cards[p];
      if (card != null) _holderOf[p] = -1; // played
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
    return true;
  }

  /// This seat's pass of [positions] to [to]: for each, the token that
  /// opens it — sealed to the receiver, its proof in the clear (the
  /// proof says nothing without the point), or in the clear outright
  /// when the receiver's secret is public — and the positions, for
  /// all to see move.
  Map<String, Object?>? passMessage(int to, List<int> positions) {
    final me = mySeat;
    if (me == null || deck == null) return null;
    final tokens = <Uint8List>[];
    for (final p in positions) {
      if (_holderOf[p] != me) return null;
      final t = _tokens[p ~/ _handSize]?[p];
      if (t == null) return null;
      tokens.add(t);
    }
    if (_public(to)) {
      return {'from': me, 'to': to, 'positions': positions, 'tokens': [for (final t in tokens) _b64(t)]};
    }
    return {
      'from': me,
      'to': to,
      'positions': positions,
      'sealed': [for (final t in tokens) _b64(crypto.seal(_pks[to]!, t, _draw()))],
      'proofs': [for (final t in tokens) _b64(Uint8List.sublistView(t, pointBytes))],
    };
  }

  /// A pass, from a person: the positions change hands; tokens in the
  /// clear are checked by all, sealed ones by whoever holds the
  /// receiver's secret — the receiver, or everyone once it has left.
  bool acceptPass(Map<String, Object?> m) {
    try {
      final from = m['from'] as int;
      final to = m['to'] as int;
      final positions = [for (final p in m['positions'] as List) p as int];
      if (positions.any((p) => p < 0 || p >= deckSize || _holderOf[p] != from)) return false;
      if (positions.toSet().length != positions.length) return false;
      final clear = m['tokens'];
      if (clear != null) {
        final tokens = [for (final t in clear as List) _unb64(t)];
        if (tokens.length != positions.length) return false;
        for (var i = 0; i < positions.length; i++) {
          final p = positions[i];
          if (!crypto.verifyToken(_pks[p ~/ _handSize]!, _masked(p), tokens[i])) return false;
        }
        for (var i = 0; i < positions.length; i++) {
          _tokens.putIfAbsent(positions[i] ~/ _handSize, () => {})[positions[i]] = tokens[i];
        }
      } else {
        final sealed = [for (final s in m['sealed'] as List) _unb64(s)];
        final proofs = [for (final s in m['proofs'] as List) _unb64(s)];
        if (sealed.length != positions.length || proofs.length != positions.length) return false;
        final keep = _sealedTo.putIfAbsent(to, () => {});
        for (var i = 0; i < positions.length; i++) {
          if (sealed[i].length != sealedBytes || proofs[i].length != tokenBytes - pointBytes) return false;
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

  /// A pass from a seat whose secret is public here — a bot's — needs
  /// no message: the positions move, and everyone can open them.
  bool passOpen(int from, int to, List<int> positions) {
    if (!_public(from)) return false;
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
      if (!_human(about) || !_gone.contains(about) || piece.length != 32) return false;
      final custodianKeys = _custodiansOf[about] ?? const <String>[];
      final seatKeys = {for (var s = 0; s < _seats; s++) if (s != about && _human(s)) _keyOf(s)};
      if (!seatKeys.contains(holder) && !custodianKeys.contains(holder)) return false;
      if (_secrets.containsKey(about)) return true;
      final got = _released.putIfAbsent(about, () => {});
      got[holder] = piece;
      // This side's own piece counts, released or not.
      final own = _myPieceOf[about];
      final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
      if (own != null && k != null) got[k] = own;
      final pk = _pks[about]!;
      if (custodianKeys.isEmpty) {
        if (!seatKeys.every(got.containsKey)) return true;
        var secret = Uint8List(32);
        for (final k in seatKeys) {
          secret = _xor(secret, got[k]!);
        }
        if (_same(crypto.keygen(secret), pk)) _learnSecret(about, secret);
        return true;
      }
      for (final s in seatKeys) {
        for (final j in custodianKeys) {
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

  /// A seat's secret at the audit, with any it vouches for: each kept
  /// when it is the one behind that seat's key; then every card those
  /// seats held is open.
  bool acceptAudit(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_human(seat)) return false;
      final secret = _unb64(m['secret']);
      if (!_secrets.containsKey(seat)) {
        if (!_same(crypto.keygen(secret), _pks[seat]!)) return false;
        _learnSecret(seat, secret);
      }
      final known = m['known'];
      if (known is Map) {
        for (final e in known.entries) {
          final s = int.parse(e.key as String);
          if (_secrets.containsKey(s) || !_human(s)) continue;
          final other = _unb64(e.value);
          if (_same(crypto.keygen(other), _pks[s]!)) _learnSecret(s, other);
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
