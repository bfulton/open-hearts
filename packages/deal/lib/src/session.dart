/// One hand's deal, from one seat's side — or from nobody's, for the
/// house following a table as a custodian, or the verifier. The protocol of
/// docs/explanation/fair-deal.md as a state machine over the primitives in
/// deal.dart: everyone's keys, four shuffles in seat order with their
/// arguments, reveal tokens for the other seats' positions, one's own
/// cards opened, the holder of the lead card declared; then, through
/// the hand, a pass as tokens sealed to the receiver, a play as the
/// token that opens its position for all, a departed seat's secret
/// rebuilt from the pieces it escrowed, and at the end every secret
/// revealed so the whole hand can be checked by anyone.
///
/// A bot seat nobody holds — the solo game's — has no secrets: its
/// deal secret is a hash everyone can compute, so its keys, shuffle and
/// tokens are computed by everyone rather than sent, and its hand is
/// open to all. A bot seat the house holds has a secret of its own,
/// which the house can make again and escrows to nobody. A person's
/// hand is known to that person alone until the audit; a person who
/// leaves becomes a bot whose secret the others rebuild.
///
/// **Escrow.** Each person splits their secret in two: one piece to
/// every other person at the table, one piece to every custodian — the
/// house, at a refereed table (docs/explanation/fair-deal.md) — each
/// copy wrapped in the secret the two keys share. Any one person and
/// any one custodian can rebuild it once the table has removed the
/// seat; all the people together hold noise without a custodian's
/// piece, and the custodians hold noise without a person's. With no
/// custodian to escrow to, the pieces to the other people are distinct
/// and all of them are needed, so a second departure in one hand
/// cannot be played on — the custodian is what a sealed table is built
/// for.
///
/// **A v2 game's jury.** A game kept before the referee escrowed to a
/// jury of several custodians, bot seats too: a bot seat's secret in
/// shares any [escrowThreshold] of them rebuild, its pieces released
/// sealed among them. Those games are still read (packages/table,
/// legacy/v2_record.dart), which rebuilds such a seat from the pieces
/// its record released; a refereed table uses none of it.
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

  /// The table key of whoever holds this seat, hex: the house's, at a
  /// live table; null in a solo game, where a bot's steps are public
  /// work everyone computes.
  final String? key;
}

const _seats = 4;
const _handSize = 13;

/// A seal as a pass made before carried it: the seal and its argument,
/// and after them a token's proof, hidden under a pad or (as the proof's
/// own field put after it) in the clear ([DealSession.readsOldPasses]).
const _oldPassSealBytes = passSealBytes + tokenProofBytes;

String _b64(Uint8List b) => base64.encode(b);
Uint8List _unb64(Object? s) => Uint8List.fromList(base64.decode(s as String));

class DealSession {
  /// Hears what this session turned down and why, for a trace: a step
  /// it could not read, a seal that opened nothing. Off by default.
  void Function(String line)? log;

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
    this.readsOldPasses = false,
    Uint8List? mySecret,
    Random? random,
  })  : _random = random ?? Random.secure() {
    if (seats.length != _seats) throw ArgumentError('four seats');
    if (mySeat != null && !_keyed(mySeat!)) throw ArgumentError('a seat with a key of its own');
    if (mySeat != null && wrap == null) throw ArgumentError('a seat wraps its escrow');
    for (var s = 0; s < _seats; s++) {
      // A bot seat with no key is the solo game's, and everyone
      // computes it from what everyone knows. One the house holds has a
      // secret of its own, and only its holder has it.
      if (!_keyed(s)) {
        _secrets[s] = botSecret(tableId, tableSeed, hand, s);
        _inTheOpen.add(s);
      } else if (s == mySeat) {
        _secrets[s] = mySecret ?? _draw();
      }
    }
    for (final s in _secrets.keys) {
      _pks[s] = crypto.keygen(_secrets[s]!);
    }
    _afterKeys(); // four bots nobody holds have every key already
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

  /// This side's table key, when it may be escrowed to as a custodian:
  /// the house's.
  final String? myKey;

  /// The secret this side's key shares with another table key —
  /// Signer.sharedSecretWith — for wrapping escrow. Null for the
  /// verifier, which opens nothing.
  final Uint8List Function(String otherKey)? wrap;

  /// Table keys of the custodians this seat escrows to: the house's,
  /// at a refereed table.
  final List<String> custodians;

  /// Whether this side also reads a pass as passes were made before
  /// the seat it was for played its card with an opening of its own:
  /// with a proof of the token beside each seal, in the clear
  /// (`proofs`), or after it under a pad ([_passPad]). Only for the
  /// verifiers of games kept then, which are kept for good; a table
  /// never takes such a pass, and a side that does not read them
  /// refuses one for the size of its seals or the field beside them.
  final bool readsOldPasses;

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

  /// Passes sealed to a seat, by position, kept until its secret is
  /// known here — the receiver's own, or a departed receiver's. Each
  /// is a seal whole, as a pass carried it ([passSealBytes], or the
  /// size of a pass made before, [_oldPassSealBytes]).
  final Map<int, Map<int, Uint8List>> _sealedTo = {};

  /// The seal itself, by position, of each card passed under a seal as
  /// passes are made now: kept by every side, for good, because the
  /// card is played with the seat's opening of this and every side
  /// checks the opening against it.
  final Map<int, Uint8List> _sealOf = {};

  /// The positions whose seal came with its proof in the clear, from a
  /// pass made before ([readsOldPasses]).
  final Set<int> _proofsInTheClear = {};

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

  /// A person's seat, as against a bot's however the bot is held: what
  /// escrow routing turns on, since a bot seat's pieces, where it has
  /// any, go to custodians alone.
  bool _human(int seat) => seats[seat] is HumanDealSeat;

  /// A seat that holds a key of its own and so acts for itself: a
  /// person's, or a bot seat the house holds. A bot seat without a key
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

  /// A departed seat whose secret this side does not know yet.
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

  /// This side's own seat's secret, for a session built again for the
  /// same hand to go on with: the keys already said are this secret's,
  /// and a session drawing another would hold its own seat's key apart
  /// from everybody else's.
  Uint8List? get mySecret => mySeat == null ? null : _secrets[mySeat!];

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
    // Nobody at the table holds a piece of a bot seat: what escrow it
    // has is its custodians' alone, both sides of it. A person's seat
    // gives one to each of the other people.
    final others = _human(me) ? [for (var s = 0; s < _seats; s++) if (s != me && _human(s)) s] : const <int>[];
    final pieces = <String, String>{};
    final custody = <String>[];
    if (custodians.isNotEmpty) {
      // One piece to each of the two sides the seat escrows across:
      // the other people and the custodians for a person's seat, the
      // custodians split in two for a bot seat a v2 game's juror held.
      if (_thresholdEscrow(me, custodians)) {
        // A bot seat's secret, in a v2 game, is its jury's alone, and
        // in shares any [escrowThreshold] of which rebuild it: one
        // custodian is still nothing, and losing one does not take the
        // seat with it.
        // A share's index is its custodian's place in the list,
        // counted from one, which is what the coefficients need.
        final shares = crypto.shareBytes(secret, n: custodians.length, t: escrowThreshold, seed: _seed('escrow', me));
        // The seat's own holder is one of the custodians, and keeps the
        // share made out to its place, as each of the others keeps
        // theirs from these keys.
        final mine = myKey == null ? -1 : custodians.indexOf(myKey!);
        for (var i = 0; i < custodians.length; i++) {
          final share = Uint8List.sublistView(shares, i * secret.length, (i + 1) * secret.length);
          custody.add(_b64(_wrapFor(custodians[i], share, me)));
          if (i == mine) _myPieceOf[me] = Uint8List.fromList(share);
        }
      } else {
        // A person's seat splits across the other people and the
        // custodians: one live custodian of any answers it.
        final (sideA, sideB) = _escrowSides(me, custodians);
        final first = _draw();
        final second = _xor(secret, first);
        for (final s in others) {
          pieces['$s'] = _b64(_wrapFor(_keyOf(s), first, me));
        }
        for (final j in custodians) {
          // Every custodian gets its own entry at its own index, whichever
          // side it is on, so opening one is the same either way.
          custody.add(_b64(_wrapFor(j, sideA.contains(j) ? first : second, me)));
        }
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
    // And who they went to, as every other side learns it from these
    // keys ([acceptKeys]), so that this seat's list can grow as theirs
    // does and its own share be weighed at its place in it.
    _custodiansOf[me] = List.of(custodians);
    _keysIn.add(me);
    final made = _myKeysMessage = {
      'seat': me,
      'pk': _b64(_pks[me]!),
      'proof': _b64(proof),
      'pieces': pieces,
      'custodians': custodians,
      'custody': custody,
      // The key's shares went here once, each wrapped under the same
      // pad as the piece beside it, which let anyone reading the log
      // work out five bits of the secret; nothing read the shares. The
      // fields stay, empty, so the message keeps the shape every build
      // reads.
      'shares': const <String, String>{},
      'shareCustody': const <String>[],
      'shareKeys': const <String>[],
    };
    _afterKeys();
    return made;
  }

  Map<String, Object?>? _myKeysMessage;

  /// The seats whose keys are in: taken, or this side's own as it made
  /// them. A seat's key known here is not enough — this side's own is
  /// known from its secret before anyone has its keys — and a seat that
  /// goes before its keys are in takes the public secret everywhere.
  final Set<int> _keysIn = {};

  Uint8List _xor(Uint8List a, Uint8List b) => Uint8List.fromList([for (var i = 0; i < a.length; i++) a[i] ^ b[i]]);

  /// Whether [seat]'s secret is escrowed as a threshold over all its
  /// custodians rather than across two sides. A bot seat is, when there
  /// are enough custodians to make a threshold of, as in a v2 game; a
  /// person's seat is not, since its two sides are the other people and
  /// the custodians, and one live custodian of any answers that.
  bool _thresholdEscrow(int seat, List<String> custodians) => !_human(seat) && custodians.length >= escrowThreshold;

  /// The two sides a seat's secret is escrowed across, one piece each,
  /// so that one holder from each rebuilds it and neither side alone
  /// is anything.
  ///
  /// A person's seat splits across the other people and the
  /// custodians. A bot seat splits the custodians in two and gives the
  /// people nothing: a player with one custodian's help is exactly what
  /// a bot's hand is hidden from, so handing players a piece would undo
  /// the whole of it. The price is that a bot seat wants two live
  /// custodians where a person's wants one of each; with one custodian
  /// the second side is empty and the seat cannot be opened at all,
  /// which is the table's business to avoid, not the deal's: a refereed
  /// table's house escrows its bot seats to nobody.
  (List<String>, List<String>) _escrowSides(int seat, List<String> custodianKeys) {
    if (_human(seat)) {
      return ([for (var s = 0; s < _seats; s++) if (s != seat && _human(s)) _keyOf(s)], custodianKeys);
    }
    final half = (custodianKeys.length + 1) ~/ 2;
    return (custodianKeys.take(half).toList(), custodianKeys.skip(half).toList());
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
      // The key's shares, in a keys message from an older build that
      // made them ([myKeys]). Their keys must add to the seat's own,
      // which every side checks, as every side did; nothing reads the
      // shares themselves.
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
      return pk.length == pointBytes && proof.length == keyProofBytes && crypto.verifyKey(pk, _name(seat), proof);
    } catch (e) {
      return _refuse('keys', e, false);
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
        // The same seat again — or this side's own, whose key was here
        // from the start. Its escrow is the message's all the same, for
        // a session that did not make it: one built again from the log,
        // or on a device back after a reload.
        if (!_custodiansOf.containsKey(seat) && _same(_unb64(m['pk']), _pks[seat]!) && (verified || verifyKeys(m))) {
          _keysIn.add(seat);
          _keyProofs[seat] ??= _unb64(m['proof']);
          _custodiansOf[seat] = [for (final k in m['custodians'] as List) k as String];
        }
        _afterKeys();
        return true;
      }
      if (!verified && !verifyKeys(m)) return false;
      final pk = _unb64(m['pk']);
      final proof = _unb64(m['proof']);
      final custodianKeys = [for (final k in m['custodians'] as List) k as String];
      final custody = [for (final c in m['custody'] as List) _unb64(c)];
      final pieces = Map<String, Object?>.from(m['pieces'] as Map);
      _pks[seat] = pk;
      _keysIn.add(seat);
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
    } catch (e) {
      return _refuse('keys', e, false);
    }
  }

  /// A person has left the table. Without keys in yet, the seat is a
  /// bot from here, secret and all; with them, its secret is awaited
  /// from the pieces the others hold.
  void seatLeft(int seat) {
    if (!_keyed(seat) || _gone.contains(seat)) return;
    _gone.add(seat);
    // A seat that goes before its keys are read is a bot from there,
    // and a bot's secret is the one anybody can compute.
    //
    // Only where there was nobody to have drawn one. A bot seat the
    // house holds has a key of its own, drawn exactly so that the
    // table cannot work its hand out, and the public secret opens
    // nothing of it. Taking it anyway is worse than knowing nothing:
    // this side would believe it held the seat's hand, so it would
    // stop awaiting the escrow and never say the piece it holds — and
    // the custodians that could have opened the seat between them would
    // wait on a release that never came. A held seat's keys are read
    // or the seat is awaited; they are never guessed.
    if (!_keysIn.contains(seat) && !_heldBot(seat)) {
      _secrets[seat] = botSecret(tableId, tableSeed, hand, seat);
      _inTheOpen.add(seat);
      _pks[seat] = crypto.keygen(_secrets[seat]!);
      _afterKeys();
    }
  }

  /// A bot seat somebody holds — the house, at a live table: it carries
  /// the holder's table key, where one nobody holds carries none.
  bool _heldBot(int seat) => switch (seats[seat]) {
        BotDealSeat(:final key) => key != null,
        HumanDealSeat() => false,
      };

  /// Every key in: the joint key, and the deck before anyone shuffles
  /// — once there is an answer for it, when the slow calls are made
  /// elsewhere ([wanted]).
  void _afterKeys() {
    if (_decks.isNotEmpty) return;
    for (var s = 0; s < _seats; s++) {
      if (!_keysIn.contains(s) && !_inTheOpen.contains(s)) return;
    }
    final joint = _joint ??= crypto.aggregate([for (var s = 0; s < _seats; s++) _pks[s]!]);
    if (!_ready(InitialDeckJob(joint))) return;
    _decks.add(crypto.initialDeck(joint));
    _computeWhatCan();
  }

  /// A seat whose steps are everyone's to compute: a bot's, or a
  /// departed person's once its secret is rebuilt. A person still at
  /// the table makes its own, even to a side that has come to know
  /// its secret — the verifier, reading the audit ahead.
  bool _public(int seat) => (!_keyed(seat) || _gone.contains(seat)) && _secrets.containsKey(seat);

  /// Every step of a seat whose secret is public here is public work:
  /// shuffles as far as they are next; and with the deck done, tokens
  /// for every seat whose secret this side holds, to open its cards.
  /// As far as there are answers, when the slow calls are made
  /// elsewhere: the rest is [wanted], and [resume] goes on from there.
  void _computeWhatCan() {
    while (nextShuffler != null && _public(nextShuffler!)) {
      final s = nextShuffler!;
      if (!_ready(ShuffleJob(_joint!, _decks.last, _seed('shuffle', s)))) return;
      final r = crypto.shuffle(_joint!, _decks.last, _seed('shuffle', s));
      _decks.add(r.deck);
      _shuffleProofs[s] = r.proof;
    }
    if (deck == null) return;
    for (var s = 0; s < _seats; s++) {
      // This side's own seat's are its own to make, but where its person
      // has gone: then they are everyone's.
      if ((s != mySeat || _gone.contains(s)) && _secrets.containsKey(s)) _tokensBy(s, everyPosition: true);
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

  /// A seed for one of [seat]'s steps, drawn from its secret. A seat
  /// whose secret is public shuffles with one, which every side must
  /// make alike, and every proof of a token takes its nonce from one.
  ///
  /// A proof's seed also takes [about], the masked cards the proof is
  /// about, so two proofs about different cards never share a nonce.
  /// Two proofs with one nonce give the key away to anyone holding
  /// both. That would happen if one secret answered for two decks of
  /// the same hand, as it could if a device that reloaded were served
  /// a different log.
  Uint8List _seed(String step, int seat, [Uint8List? about]) =>
      Uint8List.fromList(sha256.convert([...utf8.encode('$step|'), ..._secrets[seat]!, ...?about]).bytes);

  // ---- shuffles --------------------------------------------------------

  /// This seat's shuffle, when it is next; null otherwise or done.
  Map<String, Object?>? myShuffle() {
    final me = mySeat;
    if (me == null || nextShuffler != me) return null;
    final r = crypto.shuffle(_joint!, _decks.last, _myShuffleSeed ??= _draw());
    _decks.add(r.deck);
    _shuffleProofs[me] = r.proof;
    _computeWhatCan();
    return {'seat': me, 'deck': _b64(r.deck), 'proof': _b64(r.proof)};
  }

  /// Drawn once, when the shuffle is first asked for or first
  /// described ([workToMake]): the shuffle made is the one described.
  Uint8List? _myShuffleSeed;

  /// Whether a seat's shuffle is its to make now and its argument
  /// verifies against the deck before it. Changes nothing.
  bool verifyShuffle(Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      if (nextShuffler != seat || !_keyed(seat) || _public(seat)) return false;
      final next = _unb64(m['deck']);
      final proof = _unb64(m['proof']);
      return next.length == deckBytes && crypto.verifyShuffle(_joint!, _decks.last, next, proof);
    } catch (e) {
      return _refuse('a shuffle', e, false);
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
    } catch (e) {
      return _refuse('a shuffle', e, false);
    }
  }

  // ---- work elsewhere ----------------------------------------------------

  /// The slow calls checking [m], a step of [round] by another seat,
  /// will make: what a side with a worker has made there first
  /// ([DealWorker], [PreparedDeal]). Empty for a step that fails
  /// before any of them, or that makes none. Changes nothing.
  ///
  /// Each is the call [verifyShuffle] or [verifyTokens] makes, on the
  /// same inputs, so that the answer made elsewhere is the one found
  /// here. A description that drifted from the call would be a call
  /// with no answer, which is refused and raised
  /// ([UndescribedDealCall]). What taking a step goes on to cost — the
  /// first deck, a departed seat's shuffle or tokens — is not a check
  /// and is not described here: the session asks for it as it gets
  /// there ([wanted]).
  List<DealJob> workToTake(int round, Map<String, Object?> m) {
    try {
      final seat = m['seat'] as int;
      switch (round) {
        case 1:
          if (_joint == null || nextShuffler != seat || !_keyed(seat) || _public(seat)) return const [];
          final next = _unb64(m['deck']);
          if (next.length != deckBytes) return const [];
          return [VerifyShuffleJob(_joint!, _decks.last, next, _unb64(m['proof']))];
        case 2:
          final pk = _pks[seat];
          if (!_keyed(seat) || deck == null || _public(seat) || pk == null) return const [];
          final owed = _owed(seat);
          final batch = _unb64(m['tokens']);
          if (batch.length != tokensBytes(owed.length)) return const [];
          return [VerifyTokensJob(pk, _cardsAt(owed), batch)];
      }
    } catch (e) {
      // A step whose message is not the shape its round reads is no
      // step: nothing to check, and nothing taken.
      log?.call('round $round: a step this side cannot read: $e');
    }
    return const [];
  }

  /// The slow calls this side's own step of [round] will make: its
  /// shuffle ([myShuffle]), or its tokens and then its own thirteen
  /// ([myTokens]). Empty when the step is not this side's to make yet.
  List<DealJob> workToMake(int round) {
    final me = mySeat;
    if (me == null) return const [];
    switch (round) {
      case 1:
        if (nextShuffler != me || _joint == null) return const [];
        return [ShuffleJob(_joint!, _decks.last, _myShuffleSeed ??= _draw())];
      case 2:
        if (deck == null) return const [];
        final had = _tokens[me] ?? const <int, Uint8List>{};
        final own = [for (var p = 0; p < deckSize; p++) if (p ~/ _handSize == me && had[p] == null) p];
        return [
          if (_myTokens == null) _tokensJob(me, _owed(me)),
          if (own.isNotEmpty) _tokensJob(me, own),
        ];
    }
    return const [];
  }

  /// The slow calls the session came to on its own and had no answer
  /// for: the first deck once the keys are in, and the public work of a
  /// seat whose secret is known here — a bot nobody holds, a departed
  /// person's rebuilt from the escrow. These are not a step anybody
  /// sent and cannot be described ahead of the step that sets them
  /// off, so the session asks for them as it gets there, stops, and
  /// goes on from where it stopped when [resume] is called with the
  /// answers put by. Never made here: with no [PreparedDeal] behind
  /// the session there is nothing to wait for and this stays empty.
  List<DealJob> get wanted => List.of(_wanted.values);
  final Map<String, DealJob> _wanted = {};

  /// Whether [job]'s answer is at hand; if not, it is [wanted].
  bool _ready(DealJob job) {
    final c = crypto;
    if (c is! PreparedDeal || c.has(job)) return true;
    _wanted[job.key] = job;
    return false;
  }

  /// Goes on with what was [wanted], as far as its answers go: from
  /// each place the session stops to ask — the first deck, public work,
  /// and this side's own thirteen tokens once it has said its batch.
  void resume() {
    if (_wanted.isEmpty) return;
    _wanted.clear();
    _afterKeys();
    final me = mySeat;
    if (me != null && _myTokens != null) _tokensBy(me, everyPosition: true);
    _computeWhatCan();
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
    final job = _tokensJob(seat, want);
    if (!_ready(job)) return;
    _spread(t, want, crypto.revealTokens(job.secret, job.cards, job.seed));
  }

  /// [seat]'s batch of tokens for [positions]: what [workToMake]
  /// describes, and [myTokens] and [_tokensBy] make, alike.
  RevealTokensJob _tokensJob(int seat, List<int> positions) {
    final cards = _cardsAt(positions);
    return RevealTokensJob(_secrets[seat]!, cards, _seed('tokens ${positions.length}', seat, cards));
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
  /// a proof three times its own size: the proofs would all say the
  /// same thing about the same key, and a batch says it once
  /// ([DealCrypto.revealTokens]).
  Map<String, Object?>? myTokens() {
    final me = mySeat;
    if (me == null || deck == null) return null;
    final owed = _owed(me);
    final job = _tokensJob(me, owed);
    final batch = _myTokens ??= crypto.revealTokens(job.secret, job.cards, job.seed);
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
    } catch (e) {
      return _refuse('tokens', e, null);
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
      // This side's own batch, come back to it from outside — a client
      // built again after a reload, reading its own steps back from its
      // journal: what [myTokens] would have done next, it does now, so
      // its own thirteen open. The seeds are the secret's, so these are
      // the tokens it made the first time.
      if (seat == mySeat && _secrets[seat] != null) {
        _myTokens ??= _unb64(m['tokens']);
        _tokensBy(seat, everyPosition: true);
      }
      _openWhatCan();
      return true;
    } catch (e) {
      return _refuse('tokens', e, false);
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
        if (_tokens[owner]?[p] != null) continue; // already opened, here
        // A seal that yields no token leaves its position shut, and
        // only that position: opening one is arithmetic that the
        // primitives refuse on a point that is not one, and a throw
        // from here would take the whole session with it. Every seal
        // is checked before its pass is taken ([verifyPass]), so
        // nothing settled gets this far.
        try {
          final point = crypto.open(secret, Uint8List.sublistView(s.value, 0, sealedBytes));
          if (s.value.length == passSealBytes) {
            // The argument every side checked says this is the share
            // the passer's key owes for the card, so it is the token,
            // and there is nothing left to check it against.
            _tokens.putIfAbsent(owner, () => {})[p] = point;
            continue;
          }
          // A pass made before: the token's proof came with it.
          final hidden = Uint8List.sublistView(s.value, sealedBytes + sealProofBytes);
          final proof = _proofsInTheClear.contains(p)
              ? hidden
              : _xor(hidden, _passPad(crypto.sharedSecret(secret, _pks[owner]!), owner, e.key, p));
          final token = Uint8List.fromList([...point, ...proof]);
          if (crypto.verifyToken(_pks[owner]!, _masked(p), token)) {
            _tokens.putIfAbsent(owner, () => {})[p] = DealCrypto.tokenOf(token);
            _passed.putIfAbsent(owner, () => {})[p] = token;
          }
        } catch (e) {
          log?.call('position $p: a seal that opens nothing: $e');
        }
      }
      _sealedTo.remove(e.key);
    }
    final pks = [for (var s = 0; s < _seats; s++) _pks[s]!];
    for (var p = 0; p < deckSize; p++) {
      if (_cards.containsKey(p)) continue;
      final tokens = <Uint8List>[];
      for (var s = 0; s < _seats; s++) {
        final t = _tokens[s]?[p];
        if (t == null) break;
        tokens.add(t);
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
    // With its proof, since it travels alone and nothing else here
    // vouches for it; what this side keeps is still the bare token.
    return {'seat': me, 'position': p, 'token': _b64(crypto.revealToken(_secrets[me]!, _masked(p), _seed('declare $p', me, _masked(p))))};
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
    } catch (e) {
      return _refuse('a lead declaration', e, false);
    }
  }

  /// The card at [p] given [proof] as [owner]'s, without keeping
  /// either: null unless the proof checks ([_checkedToken]) and every
  /// other token for the position is in. Remembered, so that taking
  /// the same proof after checking it costs nothing more.
  int? _openWith(int owner, int p, Uint8List proof) {
    if (proof.length != tokenBytes) return null;
    final seen = _checked[p];
    if (seen != null && _same(seen.token, proof)) return seen.card;
    final token = _checkedToken(owner, p, proof);
    if (token == null) return null;
    final tokens = <Uint8List>[];
    final pks = <Uint8List>[];
    for (var s = 0; s < _seats; s++) {
      final t = s == owner ? token : _tokens[s]?[p];
      if (t == null) return null;
      tokens.add(t);
      pks.add(_pks[s]!);
    }
    final card = crypto.unmask(pks, tokens, _masked(p));
    if (card != null) _checked[p] = (token: proof, card: card);
    return card;
  }

  /// [owner]'s token for [p], bare, if [proof] makes it: null if not.
  ///
  /// Where the position was dealt to [owner] and has not been passed
  /// under a seal, [proof] is the token itself with its proof, which
  /// the owner's key checks. Where it was passed under one ([_sealOf]),
  /// the passer made no proof for anyone to carry on, and [proof] is
  /// what the seat now holding the position made of the seal with its
  /// own key: the argument that this key opens it to a point, checked
  /// against that seat's key. The argument every side checked when it
  /// took the pass says that what the seal holds is the owner's token,
  /// so the seal less that point is the token, without the owner or its
  /// proof having a say.
  Uint8List? _checkedToken(int owner, int p, Uint8List proof) {
    final seal = _sealOf[p];
    if (seal == null) return crypto.verifyToken(_pks[owner]!, _masked(p), proof) ? DealCrypto.tokenOf(proof) : null;
    final holder = _holderOf[p];
    if (holder < 0 || !crypto.verifyToken(_pks[holder]!, seal, proof)) return null;
    return crypto.openShared(seal, [proof]);
  }

  /// What a play of [p] carries its proof in: the opening of a card
  /// passed under a seal, the owner's token otherwise.
  String _proofKey(int p) => _sealOf.containsKey(p) ? 'opening' : 'token';

  /// Positions opened in a check, with the proof that did it.
  final Map<int, ({Uint8List token, int card})> _checked = {};

  /// Keeps a proof that was checked to open [p]: the card without
  /// unmasking again.
  void _keepChecked(int owner, int p, Uint8List proof) {
    final seal = _sealOf[p];
    // Bare in the store. Beside it, for a token made by its owner, the
    // proof that came in with a play: the one this side would have to
    // carry on if the position moved again ([_proved]). A card passed
    // under a seal is carried on by its holder, with an opening made
    // when it plays ([playToken]).
    _tokens.putIfAbsent(owner, () => {})[p] = seal == null ? DealCrypto.tokenOf(proof) : crypto.openShared(seal, [proof]);
    if (seal == null) _passed.putIfAbsent(owner, () => {})[p] = proof;
    final seen = _checked[p];
    if (seen != null && _same(seen.token, proof)) _cards[p] ??= seen.card;
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
    } catch (e) {
      return _refuse('a lead declaration', e, false);
    }
  }

  // ---- the hand --------------------------------------------------------

  /// What opens [position] for everyone: the token of the seat that
  /// held the position at the deal, which this side has if it is that
  /// seat or was passed the card.
  ///
  /// A card passed to a seat under a seal is opened with that seat's
  /// own word for it, an `opening`: the seal opened with its key, and
  /// the argument that this is what its key makes of it. It needs the
  /// seat's secret, so it is made where that is held: by the seat, or
  /// by whoever plays for it once its secret is rebuilt, and it is the
  /// same wherever it is made. Anything else is the owner's `token`
  /// with its proof, for a card dealt to the seat that plays it or
  /// passed in the clear ([_proved]).
  Map<String, Object?>? playToken(int position) {
    final owner = position ~/ _handSize;
    if (_tokens[owner]?[position] == null) return null;
    final seal = _sealOf[position];
    if (seal != null) {
      final holder = _holderOf[position];
      if (holder < 0 || !_secrets.containsKey(holder)) return null;
      return {'position': position, 'opening': _b64(crypto.revealToken(_secrets[holder]!, seal, _seed('opening $position', holder, seal)))};
    }
    final proved = _proved(owner, position);
    if (proved == null) return null;
    return {'position': position, 'token': _b64(proved)};
  }

  /// The owner's token for [p] with its proof beside it. The store
  /// keeps tokens bare — a proof is spent when it is checked, and
  /// opening is addition — but a token that travels alone needs one,
  /// since nothing else vouches for it. Made here when this side holds
  /// the owner's secret; otherwise the one that came with the pass
  /// that handed the card over in the clear, which is the only other
  /// way to be holding somebody else's token with its proof at all. (A
  /// card passed under a seal has none: see [playToken].)
  Uint8List? _proved(int owner, int p) {
    final secret = _secrets[owner];
    if (secret != null && deck != null) return crypto.revealToken(secret, _masked(p), _seed('play token $p', owner, _masked(p)));
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
      return _openWith(p ~/ _handSize, p, _unb64(m[_proofKey(p)]));
    } catch (e) {
      return _refuse('a play', e, null);
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
      final t = _unb64(m[_proofKey(p)]);
      if (t.length != tokenBytes) return null;
      if (!verified && _checkedToken(owner, p, t) == null) return null;
      _keepChecked(owner, p, t);
      _openWhatCan();
      final card = _cards[p];
      if (card != null) _holderOf[p] = -1; // played
      return card;
    } catch (e) {
      return _refuse('a play', e, null);
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
  /// opens it — sealed to the receiver with the argument that it is the
  /// right token, or in the clear outright when the receiver's secret
  /// is public — and the positions, for all to see move.
  ///
  /// The argument is what makes a sealed pass checkable by the rest of
  /// the table. What is sealed is for one seat's eyes, so nobody else
  /// can look; the argument says, without looking, that what is in
  /// there is the share this seat's key owes for that card
  /// (docs/explanation/fair-deal.md). Every byte of a seal is part of
  /// it, so there is nothing a passer can bend without every seat
  /// refusing the pass.
  ///
  /// The pass carries no proof of the token beside the seal. A proof
  /// of it could not be checked by anyone but the receiver, and it
  /// would name the card to anyone reading the log, since the other
  /// three seats' tokens are public and the proof verifies for exactly
  /// one of the 52 candidates. What the receiver needs when it plays
  /// the card is its own to make: the seal opened with its key, which
  /// everyone can check ([playToken]).
  ///
  /// A seat passes cards it was dealt, so every position here is its
  /// own at the deal: that is what the argument is about, and a pass of
  /// anything else is refused.
  Map<String, Object?>? passMessage(int to, List<int> positions) {
    final me = mySeat;
    final secret = _secrets[me];
    if (me == null || secret == null || deck == null) return null;
    for (final p in positions) {
      if (_holderOf[p] != me || p ~/ _handSize != me) return null;
      if (_tokens[me]?[p] == null) return null;
    }
    if (_public(to)) {
      // Made here rather than taken from the store, which keeps the
      // token alone: a token in the clear is checked by everyone, so it
      // needs its proof beside it. Deterministic, so it is the same
      // token whoever makes it.
      final tokens = [for (final p in positions) crypto.revealToken(secret, _masked(p), _seed('pass token $p', me, _masked(p)))];
      return {'from': me, 'to': to, 'positions': positions, 'tokens': [for (final t in tokens) _b64(t)]};
    }
    return {
      'from': me,
      'to': to,
      'positions': positions,
      'sealed': [for (final p in positions) _b64(crypto.seal(secret, _pks[to]!, _masked(p), _draw()))],
    };
  }

  /// What a token's proof was hidden under in a pass made before the
  /// receiver played with an opening of its own ([readsOldPasses]):
  /// [tokenProofBytes] from the secret the passer and the receiver share
  /// ([shared], from either one's secret and the other's key), for this
  /// position of this hand, so that no two proofs were hidden under the
  /// same pad. Only a seat holding either secret can make it, which is
  /// the receiver, or everyone once the receiver or the passer has left
  /// and its secret is rebuilt — whose cards are then open to all.
  ///
  /// There was no tag to check, so a passer could hide a proof that
  /// did not verify, and the receiver was left unable to open those
  /// cards: the reason passes are not made so now.
  Uint8List _passPad(Uint8List shared, int from, int to, int position) {
    final mac = Hmac(sha256, shared);
    final label = utf8.encode('pass|$tableId|$hand|$from|$to|$position|');
    final pad = <int>[];
    for (var block = 0; pad.length < tokenProofBytes; block++) {
      pad.addAll(mac.convert([...label, block]).bytes);
    }
    return Uint8List.fromList(pad.sublist(0, tokenProofBytes));
  }

  /// The seals of a sealed pass, each whole ([passSealBytes]). A pass
  /// as made before had a proof of each token beside the seals, in the
  /// clear: put after each seal here, and said to be so (`clear`),
  /// where this side reads such a pass at all ([readsOldPasses]). A
  /// side that does not refuses a pass with the field ([verifyPass]).
  ({List<Uint8List> sealed, bool clear}) _sealsOf(Map<String, Object?> m) {
    final sealed = [for (final s in m['sealed'] as List) _unb64(s)];
    final beside = readsOldPasses ? m['proofs'] : null;
    if (beside == null) return (sealed: sealed, clear: false);
    final proofs = [for (final s in beside as List) _unb64(s)];
    if (proofs.length != sealed.length) throw const FormatException('a seal for each proof');
    return (sealed: [for (final (i, s) in sealed.indexed) Uint8List.fromList([...s, ...proofs[i]])], clear: true);
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
        if (tokens.length != positions.length || tokens.any((t) => t.length != tokenBytes)) return false;
        for (var i = 0; i < positions.length; i++) {
          final p = positions[i];
          if (!crypto.verifyToken(_pks[p ~/ _handSize]!, _masked(p), tokens[i])) return false;
        }
        return true;
      }
      if (m.containsKey('proofs') && !readsOldPasses) return false;
      final (:sealed, clear: _) = _sealsOf(m);
      if (sealed.length != positions.length) return false;
      if (!sealed.every((s) => s.length == passSealBytes || (readsOldPasses && s.length == _oldPassSealBytes))) return false;
      if (_pks[from] == null || _pks[to] == null) return false;
      // Each seal's first half, the point its randomness makes, is its
      // own. With one randomness for two seals the receiver's opening of
      // the one, that point taken to its key, opens the other as well, and
      // playing one card would give another away.
      if (sealed.every((s) => s.length == passSealBytes) &&
          {for (final s in sealed) base64.encode(Uint8List.sublistView(s, 0, pointBytes))}.length != sealed.length) {
        return false;
      }
      // The argument each seal carries: what is sealed is the share
      // [from]'s key owes for that card. Checked by everyone, so a
      // receiver left with cards it cannot open is the table's
      // business, not only its own (docs/explanation/fair-deal.md).
      // The proof hidden after it is the receiver's to find out about.
      for (var i = 0; i < positions.length; i++) {
        final seal = Uint8List.sublistView(sealed[i], 0, sealedBytes + sealProofBytes);
        if (!crypto.verifySeal(_pks[from]!, _pks[to]!, _masked(positions[i]), seal)) return false;
      }
      return true;
    } catch (e) {
      return _refuse('a pass', e, false);
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
        final (:sealed, :clear) = _sealsOf(m);
        if (sealed.length != positions.length) return false;
        final keep = _sealedTo.putIfAbsent(to, () => {});
        for (var i = 0; i < positions.length; i++) {
          // The ciphertext and its argument, kept whole: the receiver
          // opens the first, and the point that comes out is the token.
          // A pass made before had a proof after them too (the point
          // plus that, uncovered, is the token), and holds no seal for
          // a play to be checked against: its play carries the token.
          keep[positions[i]] = sealed[i];
          if (clear) _proofsInTheClear.add(positions[i]);
          if (sealed[i].length == passSealBytes) _sealOf[positions[i]] = Uint8List.sublistView(sealed[i], 0, sealedBytes);
        }
      }
      for (final p in positions) {
        _holderOf[p] = to;
      }
      _openWhatCan();
      return true;
    } catch (e) {
      return _refuse('a pass', e, false);
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
  /// everyone: as a person or as a custodian. Null when it holds none, or
  /// the seat is still here.
  ///
  /// A person's seat opens to the table: its hand has to be played
  /// out where everyone can see it, and every side needs the key to
  /// work its moves out and check them. So that piece goes in the
  /// clear.
  ///
  /// A bot seat's, in a v2 game, opens to its jury and to nobody else —
  /// a piece to each custodian, sealed to it — because the whole reason
  /// a juror held the seat is that nobody at the table may see its
  /// hand. Holding a piece is not what it takes to
  /// rebuild the secret: hearing [escrowThreshold] of them is, and
  /// a piece said in the clear is heard by the people playing.
  ///
  /// [inTheOpen] once the hand is over. The audit publishes every
  /// secret then, so there is nothing left to seal, and a piece the
  /// players could not read would leave a hand only the custodians could
  /// check.
  ///
  /// [only] narrows who it is sealed to, by custodian index. Every
  /// custodian already holds a piece of its own, so one more opens the
  /// seat: a piece needs to reach the custodian that will play the
  /// seat out, not all of them. The caller names the few it judges
  /// live, and says it again as that judgement changes — a piece
  /// sealed to a custodian that has itself gone is bytes nobody reads.
  Map<String, Object?>? releaseShare(int seat, {bool inTheOpen = false, Set<int>? only}) {
    final piece = _myPieceOf[seat];
    final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
    if (piece == null || k == null || !_gone.contains(seat)) return null;
    if (_human(seat) || inTheOpen) return {'about': seat, 'holder': k, 'share': _b64(piece)};
    final to = _custodiansOf[seat];
    final w = wrap;
    if (to == null || w == null) return null;
    final sealed = {
      for (var i = 0; i < to.length; i++)
        if (to[i] != k && (only == null || only.contains(i + 1))) '${i + 1}': _b64(_sealRelease(to[i], piece, seat)),
    };
    return sealed.isEmpty ? null : {'about': seat, 'holder': k, 'sealed': sealed};
  }

  /// A piece sealed to one custodian, with the secret the two table
  /// keys share. A label of its own, not [_wrapFor]'s: the same two
  /// keys wrap the seat's piece under that one, and a pad used twice
  /// over different plaintexts gives both of them away.
  Uint8List _sealRelease(String to, Uint8List piece, int seat) => _xor(piece, _pad(wrap!(to), 'release|$tableId|$hand|$seat'));

  /// The piece a release carries, as this side can read it: in the
  /// clear, or unsealed from the entry made out to this side. Null
  /// when it is sealed to custodians and this side is not one — which
  /// is every player, and is the point of sealing it.
  Uint8List? _pieceReleased(Map<String, Object?> m, int about, String holder) {
    final bare = m['share'];
    if (bare is String) {
      final piece = _unb64(bare);
      return piece.length == 32 ? piece : null;
    }
    final sealed = m['sealed'];
    final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
    final w = wrap;
    if (sealed is! Map || k == null || w == null) return null;
    final at = _custodianIndexOf(about);
    final mine = at < 1 ? null : sealed['$at'];
    if (mine is! String) return null;
    final got = _unb64(mine);
    if (got.length != 32) return null;
    return _xor(got, _pad(w(holder), 'release|$tableId|$hand|$about'));
  }

  /// Custodians added to [seat] after its keys went out: a v2 game's
  /// jury could grow over a hand, and its record says so. The index of
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

  /// This side's index among [seat]'s custodians, or zero.
  int _custodianIndexOf(int seat) {
    final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
    final have = _custodiansOf[seat];
    if (k == null || have == null) return 0;
    return have.indexOf(k) + 1;
  }

  /// A released piece, by the table key that held it. Once a person's
  /// and a custodian's — or, escrowed to no custodian, every other person's —
  /// rebuild the secret behind the seat's key, the seat's hand is
  /// open. True once the piece is kept, whether or not that was the
  /// one that did it.
  bool acceptRelease(Map<String, Object?> m) {
    try {
      final about = m['about'] as int;
      final holder = m['holder'] as String;
      if (!_keyed(about) || !_gone.contains(about)) return false;
      final piece = _pieceReleased(m, about, holder);
      if (piece == null) return false;
      final custodianKeys = _custodiansOf[about] ?? const <String>[];
      final threshold = _thresholdEscrow(about, custodianKeys);
      final (sideA, sideB) = threshold ? (custodianKeys, custodianKeys) : _escrowSides(about, custodianKeys);
      if (!sideA.contains(holder) && !sideB.contains(holder)) return false;
      final got = _released.putIfAbsent(about, () => {});
      final fresh = !_same(got[holder] ?? Uint8List(0), piece);
      got[holder] = piece;
      final open = m['share'] is String;
      if (open) _releasedOpen.putIfAbsent(about, () => {})[holder] = piece;
      if (_inTheOpen.contains(about)) return true;
      // Rebuilt from the pieces said in the open alone: the same at
      // every side, whatever pieces it holds of its own.
      final public = _releasedOpen[about];
      if (public != null) {
        final secret = _rebuild(about, public, fresh: open && fresh ? holder : null);
        if (secret != null) {
          _inTheOpen.add(about);
          if (!_secrets.containsKey(about)) _learnSecret(about, secret);
          return true;
        }
      }
      if (_secrets.containsKey(about)) return true;
      // This side's own piece counts here, released or not: the hand is
      // open to this side, and to nobody else yet.
      final own = _myPieceOf[about];
      final k = myKey ?? (mySeat == null ? null : _keyOf(mySeat!));
      final here = {...got, if (own != null && k != null) k: own};
      final secret = _rebuild(about, here, fresh: fresh ? holder : null);
      if (secret != null) _learnSecret(about, secret);
      return true;
    } catch (e) {
      return _refuse('a release', e, false);
    }
  }

  /// [about]'s secret rebuilt from [got], the pieces by their holders'
  /// table keys, or null where they do not make it. [fresh] is the
  /// holder whose piece just came in, for a threshold escrow to try
  /// each pair it makes.
  Uint8List? _rebuild(int about, Map<String, Uint8List> got, {String? fresh}) {
    final custodianKeys = _custodiansOf[about] ?? const <String>[];
    final threshold = _thresholdEscrow(about, custodianKeys);
    final (sideA, sideB) = threshold ? (custodianKeys, custodianKeys) : _escrowSides(about, custodianKeys);
    final pk = _pks[about]!;
    if (threshold) {
      // Any [escrowThreshold] of the custodians, each piece weighed by
      // what its index is worth among the ones that answered, and
      // summed. More than the threshold is the same secret, not a
      // different one, so everything in hand goes in.
      final have = [
        for (final who in got.keys)
          if (custodianKeys.contains(who)) custodianKeys.indexOf(who) + 1,
      ]..sort();
      if (have.length < escrowThreshold) return null;
      Uint8List combine(List<int> set) => crypto.bytesSum([
            for (final i in set) crypto.bytesScale(got[custodianKeys[i - 1]]!, crypto.bytesLagrange(set, i)),
          ]);
      final secret = combine(have);
      if (_same(crypto.keygen(secret), pk)) return secret;
      // One piece that is not what its place says spoils the sum of
      // them all: a custodian brought on from a redraw whose share was
      // made at another place than this side gives it, or one that
      // released something else. Any [escrowThreshold] of them that
      // agree are the secret, so each pair the new piece makes is
      // tried in turn, each against the seat's key — the pairs among
      // the rest were tried as they came.
      if (fresh == null || escrowThreshold != 2) return null;
      final mine = custodianKeys.indexOf(fresh) + 1;
      if (mine < 1) return null;
      for (final other in have) {
        if (other == mine) continue;
        final pair = [mine, other]..sort();
        final s = combine(pair);
        if (_same(crypto.keygen(s), pk)) return s;
      }
      return null;
    }
    if (custodianKeys.isEmpty) {
      if (!sideA.every(got.containsKey)) return null;
      var secret = Uint8List(32);
      for (final k in sideA) {
        secret = _xor(secret, got[k]!);
      }
      return _same(crypto.keygen(secret), pk) ? secret : null;
    }
    // One holder from each side, whoever they are: two people at a
    // table with no house, or a person and the house at a person's seat.
    for (final s in sideA) {
      for (final j in sideB) {
        final a = got[s];
        final b = got[j];
        if (a == null || b == null) continue;
        final secret = _xor(a, b);
        if (_same(crypto.keygen(secret), pk)) return secret;
      }
    }
    return null;
  }

  /// Whether everyone at the table can know [seat]'s secret from what
  /// was said at it, alike: a bot seat nobody holds, a seat gone before
  /// its keys, a departed seat opened by pieces released in the open, a
  /// seat audited. What a table decides by, where [knowsSecret] also
  /// counts what this side alone can work out.
  bool knowsInTheOpen(int seat) => _inTheOpen.contains(seat);

  /// The seats [knowsInTheOpen] holds for.
  final Set<int> _inTheOpen = {};

  /// The pieces of each departed seat's secret released in the open, by
  /// holder.
  final Map<int, Map<String, Uint8List>> _releasedOpen = {};


  void _learnSecret(int seat, Uint8List secret) {
    _secrets[seat] = secret;
    _computeWhatCan();
  }

  /// [no], with why [what] was refused said to [log]: a message that
  /// throws on reading is refused like one that reads and does not
  /// hold, and the trace says which it was.
  T _refuse<T>(String what, Object e, T no) {
    log?.call('$what refused: $e');
    return no;
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
    } catch (e) {
      return _refuse('an audit', e, false);
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
      _inTheOpen.add(seat);
      final known = m['known'];
      if (known is Map) {
        for (final e in known.entries) {
          final s = int.parse(e.key as String);
          if (!_keyed(s)) continue;
          final said = _unb64(e.value);
          // Said in an audit, so said to everyone: in the open once it
          // is the seat's key's secret.
          if (_pks[s] == null || !_same(crypto.keygen(said), _pks[s]!)) continue;
          _inTheOpen.add(s);
          if (!_secrets.containsKey(s)) _learnSecret(s, said);
        }
      }
      return true;
    } catch (e) {
      return _refuse('an audit', e, false);
    }
  }

  /// Every position's card, once every secret is known.
  Map<int, int>? get fullDeal => _cards.length == deckSize ? Map.unmodifiable(_cards) : null;

  /// The seat that held each position at the deal, for the audit's
  /// replay: 0..3 by thirteens.
  static int dealtTo(int position) => position ~/ _handSize;
}
