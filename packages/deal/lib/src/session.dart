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
    this.custodians = const [],
    Uint8List? mySecret,
    Random? random,
  })  : _random = random ?? Random.secure() {
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

  /// Whether a seat's keys message is well formed and its proof
  /// holds. Changes nothing.
  bool verifyKeys(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (seat < 0 || seat >= _seats || !_human(seat)) return false;
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
      if (seat < 0 || seat >= _seats || !_human(seat)) return false;
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

  /// A seat whose steps are everyone's to compute: a bot's, or a
  /// departed person's once its secret is rebuilt. A person still at
  /// the table makes its own, even to a side that has come to know
  /// its secret — the verifier, reading the audit ahead.
  bool _public(int seat) => seat != mySeat && (!_human(seat) || _gone.contains(seat)) && _secrets.containsKey(seat);

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
    if (!_human(seat) || !_pks.containsKey(seat)) return false;
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
      if (nextShuffler != seat || !_human(seat) || _public(seat)) return false;
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
      if (nextShuffler != seat || !_human(seat) || _public(seat)) return false;
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

  /// Whether a seat's tokens are one for every position not its own,
  /// each verifying against its key and the dealt deck. Changes
  /// nothing.
  bool verifyTokens(Map<String, Object?> m) => _checkTokens(m) != null;

  Map<int, Uint8List>? _checkTokens(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_human(seat) || deck == null || _public(seat)) return null;
      final pk = _pks[seat]!;
      final given = Map<String, Object?>.from(m['tokens'] as Map);
      final checked = <int, Uint8List>{};
      for (var p = 0; p < deckSize; p++) {
        if (p ~/ _handSize == seat) continue;
        final t = _unb64(given['$p']);
        if (!crypto.verifyToken(pk, _masked(p), t)) return null;
        checked[p] = t;
      }
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
      if (!_human(seat) || deck == null || _public(seat)) return false;
      if (hasTokens(seat)) return true;
      final Map<int, Uint8List> checked;
      if (verified) {
        final given = Map<String, Object?>.from(m['tokens'] as Map);
        checked = {for (var p = 0; p < deckSize; p++) if (p ~/ _handSize != seat) p: _unb64(given['$p'])};
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
      if (secret == null) continue;
      for (final s in e.value.entries) {
        final p = s.key;
        final owner = p ~/ _handSize;
        // A seal that yields no token leaves its position shut, and
        // only that position: opening one is arithmetic that the
        // primitives refuse on a point that is not one, and a throw
        // from here used to take the whole session with it, so that
        // nothing else opened either. Nothing settled gets this far —
        // every seal is checked before its pass is taken
        // ([verifyPass]) — so this is the belt to that brace.
        try {
          final point = crypto.open(secret, Uint8List.sublistView(s.value, 0, sealedBytes));
          final token = Uint8List.fromList([...point, ...Uint8List.sublistView(s.value, sealedBytes + sealProofBytes)]);
          if (crypto.verifyToken(_pks[owner]!, _masked(p), token)) _tokens.putIfAbsent(owner, () => {})[p] = token;
        } catch (_) {}
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
      final c = crypto.unmask(pks, tokens, maskedAt(d, p), verified: true);
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

  /// Whether a seat's word on the lead card holds: nowhere, or a
  /// position of its own at the deal that its token opens to the lead
  /// card. Changes nothing.
  bool verifyDeclaration(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_human(seat) || deck == null) return false;
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
      final t = s == owner ? token : _tokens[s]?[p];
      if (t == null) return null;
      tokens.add(t);
      pks.add(_pks[s]!);
    }
    final card = crypto.unmask(pks, tokens, _masked(p), verified: true);
    if (card != null) _checked[p] = (token: token, card: card);
    return card;
  }

  /// Positions opened in a check, with the token that did it.
  final Map<int, ({Uint8List token, int card})> _checked = {};

  /// Keeps a token that was checked to open [p]: the card without
  /// unmasking again.
  void _keepChecked(int owner, int p, Uint8List token) {
    _tokens.putIfAbsent(owner, () => {})[p] = token;
    final seen = _checked[p];
    if (seen != null && _same(seen.token, token)) _cards[p] ??= seen.card;
  }

  /// A seat's word on the lead card. A position must be the seat's
  /// own at the deal and open, with its token, to the lead card.
  bool acceptDeclaration(Map<String, Object?> m, {bool verified = false}) {
    try {
      final seat = m['seat'] as int;
      if (!_human(seat) || deck == null) return false;
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
    final t = _tokens[owner]?[position];
    if (t == null) return null;
    return {'position': position, 'token': _b64(t)};
  }

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
      final t = _tokens[me]?[p];
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
          _tokens.putIfAbsent(positions[i] ~/ _handSize, () => {})[positions[i]] = tokens[i];
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

  /// Whether a seat's audit holds: its secret is the one behind its
  /// key, and every secret it vouches for is behind that seat's.
  /// Changes nothing.
  bool verifyAudit(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (!_human(seat) || !_pks.containsKey(seat)) return false;
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
          if (!_human(s)) continue;
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
      if (!_human(seat)) return false;
      if (!verified && !verifyAudit(m)) return false;
      final secret = _unb64(m['secret']);
      if (!_secrets.containsKey(seat)) {
        _learnSecret(seat, secret);
      }
      final known = m['known'];
      if (known is Map) {
        for (final e in known.entries) {
          final s = int.parse(e.key as String);
          if (_secrets.containsKey(s) || !_human(s)) continue;
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
