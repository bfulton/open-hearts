/// One hand's deal, from one seat's side — or from nobody's, for a
/// follower or the verifier. The protocol of docs/03-fair-deal.md as
/// a state machine over the primitives in deal.dart: everyone's keys,
/// four shuffles in seat order with their arguments, reveal tokens for
/// the other seats' positions, one's own cards opened; then, through
/// the hand, a pass as sealed tokens, a play as the token that opens
/// its position for all, a departed seat's secret rebuilt from the
/// shares it escrowed, and at the end every secret revealed so the
/// whole hand can be checked by anyone.
///
/// A bot seat has no secrets: its deal secret is a hash everyone can
/// compute, so its keys, shuffle and tokens are computed by everyone
/// rather than sent, and its hand is open to all — the interim doc 04
/// names, until the bot plays inside the computation. A human seat's
/// hand is known to that seat alone until the audit.
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
enum DealPhase { keys, shuffles, tokens, dealt, audited }

/// A seat as the deal sees it: a person, named by their key, or a bot.
sealed class DealSeat {
  const DealSeat();
}

class HumanDealSeat extends DealSeat {
  const HumanDealSeat(this.key);

  /// The seat's signing key, hex: what the deal keys are bound to.
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
    this.mySeat,
    Uint8List? mySecret,
    List<Uint8List> custodians = const [],
    Random? random,
  })  : _random = random ?? Random.secure(),
        custodians = List.unmodifiable(custodians) {
    if (seats.length != _seats) throw ArgumentError('four seats');
    if (mySeat != null && seats[mySeat!] is! HumanDealSeat) throw ArgumentError('a person\'s seat');
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
  final int? mySeat;

  /// Keys to escrow the jury's share of this seat's secret to: the
  /// jurors' deal keys. Empty, and a departure cannot be played on.
  final List<Uint8List> custodians;

  final Random _random;
  final Map<int, Uint8List> _secrets = {};
  final Map<int, Uint8List> _pks = {};
  final Map<int, Uint8List> _keyProofs = {};
  Uint8List? _joint;
  final List<Uint8List> _decks = [];
  final Map<int, Uint8List> _shuffleProofs = {};

  /// Tokens by (seat that made it, position).
  final Map<int, Map<int, Uint8List>> _tokens = {};

  /// Cards opened, by position.
  final Map<int, int> _cards = {};

  /// Which seat holds each position now (passes move them).
  late final List<int> _holderOf = [for (var p = 0; p < deckSize; p++) p ~/ _handSize];

  /// Shares of a seat's secret, as this side holds them: by the seat
  /// whose secret, then by holder (a seat, or -1 for the custodians).
  final Map<int, Map<int, Uint8List>> _shares = {};
  final Map<int, Map<int, Uint8List>> _released = {};

  /// A bot's deal secret: a hash of what everyone knows.
  static Uint8List botSecret(String tableId, int tableSeed, int hand, int seat) =>
      Uint8List.fromList(sha256.convert(utf8.encode('bot|$tableId|$tableSeed|$hand|$seat')).bytes);

  Uint8List _draw() => Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256)));

  Uint8List _name(int seat) => Uint8List.fromList(utf8.encode('$tableId|$hand|$seat'));

  // ---- where things stand ---------------------------------------------

  DealPhase get phase {
    if (_pks.length < _seats) return DealPhase.keys;
    if (_decks.length < _seats + 1) return DealPhase.shuffles;
    if (!_allTokensIn) return DealPhase.tokens;
    if (_secrets.length < _seats) return DealPhase.dealt;
    return DealPhase.audited;
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

  /// The seat whose shuffle is awaited, or null once all four are in.
  int? get nextShuffler => _decks.isEmpty || _decks.length > _seats ? null : _decks.length - 1;

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

  /// The card at a position, if opened here.
  int? cardAt(int position) => _cards[position];

  /// The position of one of this side's open cards held by [seat].
  int? positionOf(int seat, int card) {
    for (var p = 0; p < deckSize; p++) {
      if (_holderOf[p] == seat && _cards[p] == card) return p;
    }
    return null;
  }

  int holderOf(int position) => _holderOf[position];

  // ---- keys ------------------------------------------------------------

  /// This seat's keys, for everyone; null when this side has no seat.
  Map<String, Object?>? myKeys() {
    final me = mySeat;
    if (me == null) return null;
    final proof = _keyProofs[me] ??= crypto.keyProof(_secrets[me]!, _name(me), _draw());
    return {'seat': me, 'pk': _b64(_pks[me]!), 'proof': _b64(proof)};
  }

  /// Another seat's keys: kept when the proof holds. False otherwise,
  /// or when the seat is a bot (whose keys everyone computes).
  bool acceptKeys(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (seat < 0 || seat >= _seats || seats[seat] is! HumanDealSeat) return false;
      if (_pks.containsKey(seat)) return true; // the same seat again
      final pk = _unb64(m['pk']);
      final proof = _unb64(m['proof']);
      if (!crypto.verifyKey(pk, _name(seat), proof)) return false;
      _pks[seat] = pk;
      _keyProofs[seat] = proof;
      _afterKeys();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _afterKeys() {
    if (_pks.length < _seats || _joint != null) return;
    _joint = crypto.aggregate([for (var s = 0; s < _seats; s++) _pks[s]!]);
    _decks.add(crypto.initialDeck(_joint!));
    _botShuffles();
  }

  /// Every bot seat's shuffle is public work; do as many as are next.
  void _botShuffles() {
    while (nextShuffler != null && seats[nextShuffler!] is BotDealSeat) {
      final s = nextShuffler!;
      final r = crypto.shuffle(_joint!, _decks.last, _seed('shuffle', s));
      _decks.add(r.deck);
      _shuffleProofs[s] = r.proof;
    }
    if (deck != null) _botTokens();
  }

  /// Public randomness for a bot seat's step: from its public secret.
  Uint8List _seed(String step, int seat) => Uint8List.fromList(sha256.convert([...utf8.encode('$step|'), ..._secrets[seat]!]).bytes);

  // ---- shuffles --------------------------------------------------------

  /// This seat's shuffle, when it is next; null otherwise or done.
  Map<String, Object?>? myShuffle() {
    final me = mySeat;
    if (me == null || nextShuffler != me) return null;
    final r = crypto.shuffle(_joint!, _decks.last, _draw());
    _decks.add(r.deck);
    _shuffleProofs[me] = r.proof;
    _botShuffles();
    return {'seat': me, 'deck': _b64(r.deck), 'proof': _b64(r.proof)};
  }

  /// A seat's shuffle: kept when it is that seat's turn and the
  /// argument verifies against the deck before it.
  bool acceptShuffle(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (_shuffleProofs.containsKey(seat)) return true;
      if (nextShuffler != seat || seats[seat] is! HumanDealSeat) return false;
      final next = _unb64(m['deck']);
      final proof = _unb64(m['proof']);
      if (next.length != deckBytes || !crypto.verifyShuffle(_joint!, _decks.last, next, proof)) return false;
      _decks.add(next);
      _shuffleProofs[seat] = proof;
      _botShuffles();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- tokens ----------------------------------------------------------

  void _botTokens() {
    for (var s = 0; s < _seats; s++) {
      if (seats[s] is BotDealSeat) _tokensBy(s, everyPosition: true);
    }
    _openWhatCan();
  }

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
      if (seats[seat] is! HumanDealSeat || deck == null) return false;
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

  /// Opens every position this side holds all four tokens for.
  void _openWhatCan() {
    final d = deck;
    if (d == null) return;
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

  /// This seat's pass of [positions] to [to]: for each, the token's
  /// point sealed to the receiver and its proof in the clear — the
  /// proof says nothing without the point — and the positions, for
  /// all to see move.
  Map<String, Object?>? passMessage(int to, List<int> positions) {
    final me = mySeat;
    if (me == null || deck == null) return null;
    final sealed = <String>[];
    final proofs = <String>[];
    for (final p in positions) {
      if (_holderOf[p] != me) return null;
      final owner = p ~/ _handSize;
      final t = _tokens[owner]?[p];
      if (t == null) return null;
      sealed.add(_b64(crypto.seal(_pks[to]!, t, _draw())));
      proofs.add(_b64(Uint8List.sublistView(t, pointBytes)));
    }
    return {'from': me, 'to': to, 'positions': positions, 'sealed': sealed, 'proofs': proofs};
  }

  /// A pass, from anyone: the positions change hands; the receiver, if
  /// this side, opens the sealed tokens, checks them, and its new cards.
  bool acceptPass(Map<String, Object?> m) {
    try {
      final from = m['from'] as int;
      final to = m['to'] as int;
      final positions = [for (final p in m['positions'] as List) p as int];
      final sealed = [for (final s in m['sealed'] as List) _unb64(s)];
      final proofs = [for (final s in m['proofs'] as List) _unb64(s)];
      if (positions.length != sealed.length || positions.length != proofs.length) return false;
      if (positions.any((p) => p < 0 || p >= deckSize || _holderOf[p] != from)) return false;
      final receiverSecret = _secrets[to];
      for (var i = 0; i < positions.length; i++) {
        final p = positions[i];
        _holderOf[p] = to;
        if (receiverSecret != null) {
          final owner = p ~/ _handSize;
          final point = crypto.open(receiverSecret, sealed[i]);
          final token = Uint8List.fromList([...point, ...proofs[i]]);
          if (crypto.verifyToken(_pks[owner]!, _masked(p), token)) _tokens.putIfAbsent(owner, () => {})[p] = token;
        }
      }
      _openWhatCan();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _startsWith(Uint8List full, Uint8List head) {
    for (var i = 0; i < head.length; i++) {
      if (full[i] != head[i]) return false;
    }
    return true;
  }

  // ---- custody ----------------------------------------------------------

  /// Shares of this seat's secret: one to each other seat, sealed
  /// with the secret the two share, and one to the custodians, sealed
  /// to each. Any three seats without the custodians' share, or the
  /// custodians without a seat's, hold noise.
  Map<String, Object?>? myShares() {
    final me = mySeat;
    if (me == null || _pks.length < _seats) return null;
    if (_mySharesMessage != null) return _mySharesMessage;
    final secret = _secrets[me]!;
    final shares = <int, Uint8List>{};
    var acc = Uint8List.fromList(secret);
    for (var s = 0; s < _seats; s++) {
      if (s == me) continue;
      final share = _draw();
      shares[s] = share;
      acc = _xor(acc, share);
    }
    final custody = acc; // secret = every seat's share xor the custodians'
    return _mySharesMessage = {
      'seat': me,
      'shares': {for (final e in shares.entries) '${e.key}': _b64(_wrap(me, e.key, e.value))},
      'custody': [for (final pk in custodians) _b64(_wrapTo(me, pk, custody))],
    };
  }

  /// The one split of this seat's secret: drawn once, so a re-send is
  /// the same message and the custodians' share fits the seats'.
  Map<String, Object?>? _mySharesMessage;

  Uint8List _xor(Uint8List a, Uint8List b) => Uint8List.fromList([for (var i = 0; i < a.length; i++) a[i] ^ b[i]]);

  /// A share for [to], encrypted with what [from] and [to] share.
  Uint8List _wrap(int from, int to, Uint8List share) {
    final key = crypto.sharedSecret(_secrets[from]!, _pks[to]!);
    return _xor(share, _pad(key, 'share|$hand|$from|$to'));
  }

  Uint8List _wrapTo(int from, Uint8List pk, Uint8List share) {
    final key = crypto.sharedSecret(_secrets[from]!, pk);
    return _xor(share, _pad(key, 'custody|$hand|$from'));
  }

  Uint8List _pad(Uint8List key, String label) => Uint8List.fromList(sha256.convert([...key, ...utf8.encode('|$label')]).bytes);

  /// Everyone keeps every seat's shares as sent; this side unwraps
  /// what was sealed to it.
  bool acceptShares(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (seats[seat] is! HumanDealSeat || _pks.length < _seats) return false;
      final shares = Map<String, Object?>.from(m['shares'] as Map);
      final kept = _shares.putIfAbsent(seat, () => {});
      for (final e in shares.entries) {
        final to = int.parse(e.key);
        final wrapped = _unb64(e.value);
        final secret = _secrets[to];
        if (secret != null) {
          final key = crypto.sharedSecret(secret, _pks[seat]!);
          kept[to] = _xor(wrapped, _pad(key, 'share|$hand|$seat|$to'));
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A custodian's view of a seat's shares message: the share sealed
  /// to it, the [index]th custodian, opened with its own deal secret.
  static Uint8List? custodyShare(DealCrypto crypto, Map<String, Object?> m, Uint8List custodianSecret, Uint8List seatPk, int hand, int index) {
    try {
      final seat = m['seat'] as int;
      final key = crypto.sharedSecret(custodianSecret, seatPk);
      final pad = Uint8List.fromList(sha256.convert([...key, ...utf8.encode('|custody|$hand|$seat')]).bytes);
      final custody = [for (final c in m['custody'] as List) Uint8List.fromList(base64.decode(c as String))];
      if (index < 0 || index >= custody.length) return null;
      return Uint8List.fromList([for (var i = 0; i < 32; i++) custody[index][i] ^ pad[i]]);
    } catch (_) {
      return null;
    }
  }

  /// This side's share of [seat]'s secret, in the clear, for release
  /// once the table has removed the seat.
  Map<String, Object?>? releaseShare(int seat) {
    final me = mySeat;
    if (me == null) return null;
    final share = _shares[seat]?[me];
    if (share == null) return null;
    return {'about': seat, 'holder': me, 'share': _b64(share)};
  }

  /// A released share, from a seat or from a custodian (holder -1).
  /// Once every seat's and the custodians' are in and they rebuild
  /// the secret behind the seat's key, the seat's hand is open.
  bool acceptRelease(Map<String, Object?> m) {
    try {
      final about = m['about'] as int;
      final holder = m['holder'] as int;
      final share = _unb64(m['share']);
      if (seats[about] is! HumanDealSeat || _secrets.containsKey(about)) return _secrets.containsKey(about);
      final got = _released.putIfAbsent(about, () => {});
      got[holder] = share;
      // Bot seats' shares are public: this side unwrapped them itself.
      for (var s = 0; s < _seats; s++) {
        if (s != about && seats[s] is BotDealSeat) {
          final mine = _shares[about]?[s];
          if (mine != null) got[s] = mine;
        }
      }
      final needed = [for (var s = 0; s < _seats; s++) if (s != about) s, -1];
      if (!needed.every(got.containsKey)) return true;
      var secret = got[-1]!;
      for (final s in needed) {
        if (s != -1) secret = _xor(secret, got[s]!);
      }
      if (!_same(crypto.keygen(secret), _pks[about]!)) {
        _released.remove(about); // a wrong share among them: wait for better ones
        return false;
      }
      _secrets[about] = secret;
      _tokensBy(about, everyPosition: true);
      _openWhatCan();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _same(Uint8List a, Uint8List b) => a.length == b.length && _startsWith(a, b);

  // ---- the audit --------------------------------------------------------

  /// This seat's secret, for everyone, once the hand is over.
  Map<String, Object?>? myAudit() {
    final me = mySeat;
    if (me == null) return null;
    return {'seat': me, 'secret': _b64(_secrets[me]!)};
  }

  /// A seat's secret at the audit: kept when it is the one behind the
  /// seat's key; then every card the seat held is open.
  bool acceptAudit(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (_secrets.containsKey(seat)) return true;
      final secret = _unb64(m['secret']);
      if (!_same(crypto.keygen(secret), _pks[seat]!)) return false;
      _secrets[seat] = secret;
      _tokensBy(seat, everyPosition: true);
      _openWhatCan();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Every position's card, once every secret is known.
  Map<int, int>? get fullDeal => _cards.length == deckSize ? Map.unmodifiable(_cards) : null;
}
